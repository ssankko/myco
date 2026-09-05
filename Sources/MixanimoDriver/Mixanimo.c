//  AudioServerPlugIn that publishes the two Mixanimo virtual devices.
//  Loaded by coreaudiod from /Library/Audio/Plug-Ins/HAL/Mixanimo.driver.

#include "MixanimoDriver.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#pragma mark - Configuration

//  The one place the driver version lives; the app reads it through the 'mxvr' custom property.
#define kDriverVersion  CFSTR("0.2.0")

#define kBoxUID         CFSTR("com.mixanimo.box")
#define kManufacturer   CFSTR("Mixanimo")
#define kBundleID       CFSTR("com.mixanimo.driver")
#define kAppBundleID    CFSTR("com.mixanimo.app")

enum
{
    kObjectID_Box               = 2,
    kObjectID_Device_Out        = 3,
    kObjectID_Stream_Out_Input  = 4,
    kObjectID_Stream_Out_Output = 5,
    kObjectID_Volume_Out        = 6,
    kObjectID_Mute_Out          = 7,
    kObjectID_Device_Mic        = 8,
    kObjectID_Stream_Mic_Input  = 9,
    kObjectID_Stream_Mic_Output = 10
};

//  Custom property on the plug-in object, a CFString carrying kDriverVersion.
#define kPlugInCustomProperty_Version ((AudioObjectPropertySelector)'mxvr')

//  Power of two so a sample time maps to a ring index with a mask. 65536 frames hold sixteen
//  buffers of 4096, the largest IO size the HAL asks for, at any supported rate.
#define kRingFrames             65536u

//  Sample frames between successive zero time stamps; the host rejects a period below 10923.
#define kZeroTimeStampPeriod    16384u

static const Float32    kVolumeMinDB = -96.0f;
static const Float32    kVolumeMaxDB = 0.0f;

static const Float64    kRatesOut[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
static const Float64    kRatesMic[] = { 48000.0 };

#pragma mark - State

//  One device description shared by both devices. Fields above mSampleRate never change.
//  Everything below it is written only under gStateMutex; the fields the IO thread reads are
//  atomic so the IO path takes no lock.
typedef struct
{
    AudioObjectID               mDeviceID;
    AudioObjectID               mInputStreamID;
    AudioObjectID               mOutputStreamID;
    AudioObjectID               mVolumeID;
    AudioObjectID               mMuteID;
    CFStringRef                 mUID;
    CFStringRef                 mModelUID;
    CFStringRef                 mName;
    UInt32                      mChannels;
    const Float64*              mRates;
    UInt32                      mRateCount;
    AudioObjectPropertyScope    mDefaultScope;
    Float32*                    mRing;

    Float64                     mSampleRate;
    UInt32                      mInputStreamActive;
    UInt32                      mOutputStreamActive;
    UInt32                      mIOCount;
    Float32                     mVolumeScalar;
    UInt32                      mMute;

    _Atomic UInt64              mAnchorHostTime;
    _Atomic UInt64              mTimeStampCount;
    _Atomic double              mHostTicksPerPeriod;
    _Atomic UInt64              mWriteEnd;
} DeviceState;

static Float32 gRingOut[kRingFrames * 2];
static Float32 gRingMic[kRingFrames];

static DeviceState gDevices[2] =
{
    {
        .mDeviceID = kObjectID_Device_Out,
        .mInputStreamID = kObjectID_Stream_Out_Input,
        .mOutputStreamID = kObjectID_Stream_Out_Output,
        .mVolumeID = kObjectID_Volume_Out,
        .mMuteID = kObjectID_Mute_Out,
        .mUID = CFSTR("com.mixanimo.output"),
        .mModelUID = CFSTR("com.mixanimo.output.model"),
        .mName = CFSTR("Mixanimo"),
        .mChannels = 2,
        .mRates = kRatesOut,
        .mRateCount = 6,
        .mDefaultScope = kAudioObjectPropertyScopeOutput,
        .mRing = gRingOut,
        .mSampleRate = 88200.0,
        .mInputStreamActive = 1,
        .mOutputStreamActive = 1,
        .mVolumeScalar = 1.0f
    },
    {
        .mDeviceID = kObjectID_Device_Mic,
        .mInputStreamID = kObjectID_Stream_Mic_Input,
        .mOutputStreamID = kObjectID_Stream_Mic_Output,
        .mVolumeID = kAudioObjectUnknown,
        .mMuteID = kAudioObjectUnknown,
        .mUID = CFSTR("com.mixanimo.mic"),
        .mModelUID = CFSTR("com.mixanimo.mic.model"),
        .mName = CFSTR("Mixanimo Mic"),
        .mChannels = 1,
        .mRates = kRatesMic,
        .mRateCount = 1,
        .mDefaultScope = kAudioObjectPropertyScopeInput,
        .mRing = gRingMic,
        .mSampleRate = 48000.0,
        .mInputStreamActive = 1,
        .mOutputStreamActive = 1,
        .mVolumeScalar = 1.0f
    }
};

static pthread_mutex_t          gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32                   gBoxAcquired = 1;
static Float64                  gHostTicksPerSecond = 1.0e9;

//  App processes attached through AddDeviceClient. Counted per process, so the app attaching to
//  both devices and later leaving one keeps the devices visible.
#define kMaxAppProcesses 16
static pid_t    gAppPIDs[kMaxAppProcesses];
static UInt32   gAppRefs[kMaxAppProcesses];
static UInt32   gAppProcessCount = 0;

#pragma mark - Helpers

static DeviceState* DeviceForObjectID(AudioObjectID inObjectID)
{
    for(UInt32 theIndex = 0; theIndex < 2; ++theIndex)
    {
        DeviceState* theDevice = &gDevices[theIndex];
        if((inObjectID == theDevice->mDeviceID) || (inObjectID == theDevice->mInputStreamID) ||
           (inObjectID == theDevice->mOutputStreamID) ||
           ((theDevice->mVolumeID != kAudioObjectUnknown) &&
            ((inObjectID == theDevice->mVolumeID) || (inObjectID == theDevice->mMuteID))))
        {
            return theDevice;
        }
    }
    return NULL;
}

static void FillFormat(const DeviceState* inDevice, AudioStreamBasicDescription* outFormat)
{
    UInt32 theBytesPerFrame = 4 * inDevice->mChannels;
    outFormat->mSampleRate = inDevice->mSampleRate;
    outFormat->mFormatID = kAudioFormatLinearPCM;
    outFormat->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket = theBytesPerFrame;
    outFormat->mFramesPerPacket = 1;
    outFormat->mBytesPerFrame = theBytesPerFrame;
    outFormat->mChannelsPerFrame = inDevice->mChannels;
    outFormat->mBitsPerChannel = 32;
    outFormat->mReserved = 0;
}

//  Both devices carry one stream per direction, so a scoped query sees one and a global query two.
static UInt32 StreamCountForScope(AudioObjectPropertyScope inScope)
{
    return (inScope == kAudioObjectPropertyScopeGlobal) ? 2 : 1;
}

//  A cube taper: the slider travels most of its length over the top 40 dB.
static Float32 ScalarToDecibel(Float32 inScalar)
{
    if(inScalar <= 0.0f) return kVolumeMinDB;
    Float32 theDB = 60.0f * log10f(inScalar);
    return (theDB < kVolumeMinDB) ? kVolumeMinDB : ((theDB > kVolumeMaxDB) ? kVolumeMaxDB : theDB);
}

static Float32 DecibelToScalar(Float32 inDecibel)
{
    if(inDecibel <= kVolumeMinDB) return 0.0f;
    Float32 theScalar = powf(10.0f, ((inDecibel > kVolumeMaxDB) ? kVolumeMaxDB : inDecibel) / 60.0f);
    return (theScalar > 1.0f) ? 1.0f : theScalar;
}

//  NULL while the bundle carries no icon file, which makes HasProperty report the icon absent.
static CFURLRef CopyIconURL(void)
{
    CFBundleRef theBundle = CFBundleGetBundleWithIdentifier(kBundleID);
    return (theBundle != NULL) ? CFBundleCopyResourceURL(theBundle, CFSTR("Mixanimo"), CFSTR("icns"), NULL) : NULL;
}

//  Copies as many whole elements as the caller's buffer holds; a size-only query passes outData as NULL.
static OSStatus ReturnArray(const void* inSource, UInt32 inElementSize, UInt32 inCount,
                            UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    UInt32 theCount = inCount;
    if(outData != NULL)
    {
        UInt32 theFit = inDataSize / inElementSize;
        if(theFit < theCount)
        {
            theCount = theFit;
        }
        memcpy(outData, inSource, theCount * inElementSize);
    }
    *outDataSize = theCount * inElementSize;
    return 0;
}

//  A scalar is all-or-nothing: too small a buffer is an error rather than a partial read.
#define RETURN_SCALAR(inType, inValue)                                              \
    do                                                                              \
    {                                                                               \
        if(outData != NULL)                                                         \
        {                                                                           \
            if(inDataSize < sizeof(inType)) return kAudioHardwareBadPropertySizeError; \
            *((inType*)outData) = (inValue);                                        \
        }                                                                           \
        *outDataSize = sizeof(inType);                                              \
        return 0;                                                                   \
    } while(0)

//  The conversion properties carry their argument in the answer buffer and replace it in place.
#define RETURN_CONVERTED(inExpression)                                              \
    do                                                                              \
    {                                                                               \
        if(outData != NULL)                                                         \
        {                                                                           \
            if(inDataSize < sizeof(Float32)) return kAudioHardwareBadPropertySizeError; \
            Float32 theArgument = *((const Float32*)outData);                       \
            *((Float32*)outData) = (inExpression);                                  \
        }                                                                           \
        *outDataSize = sizeof(Float32);                                             \
        return 0;                                                                   \
    } while(0)

#pragma mark - PlugIn object properties

static OSStatus PlugIn_GetProperty(const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inQualifierDataSize, const void* inQualifierData,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            RETURN_SCALAR(AudioClassID, kAudioObjectClassID);

        case kAudioObjectPropertyClass:
            RETURN_SCALAR(AudioClassID, kAudioPlugInClassID);

        case kAudioObjectPropertyOwner:
            RETURN_SCALAR(AudioObjectID, kAudioObjectUnknown);

        case kAudioObjectPropertyManufacturer:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kManufacturer));

        case kAudioObjectPropertyOwnedObjects:
        {
            AudioObjectID theList[] = { kObjectID_Box, kObjectID_Device_Out, kObjectID_Device_Mic };
            return ReturnArray(theList, sizeof(AudioObjectID), (gBoxAcquired != 0) ? 3 : 1,
                               inDataSize, outDataSize, outData);
        }

        case kAudioPlugInPropertyBoxList:
        {
            AudioObjectID theBox = kObjectID_Box;
            return ReturnArray(&theBox, sizeof(AudioObjectID), 1, inDataSize, outDataSize, outData);
        }

        case kAudioPlugInPropertyTranslateUIDToBox:
        {
            if(outData == NULL) { *outDataSize = sizeof(AudioObjectID); return 0; }
            if(inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if((inQualifierData == NULL) || (inQualifierDataSize != sizeof(CFStringRef))) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = CFEqual(*((const CFStringRef*)inQualifierData), kBoxUID) ? kObjectID_Box : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        case kAudioPlugInPropertyDeviceList:
        {
            AudioObjectID theList[] = { kObjectID_Device_Out, kObjectID_Device_Mic };
            return ReturnArray(theList, sizeof(AudioObjectID), (gBoxAcquired != 0) ? 2 : 0,
                               inDataSize, outDataSize, outData);
        }

        case kAudioPlugInPropertyTranslateUIDToDevice:
        {
            if(outData == NULL) { *outDataSize = sizeof(AudioObjectID); return 0; }
            if(inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if((inQualifierData == NULL) || (inQualifierDataSize != sizeof(CFStringRef))) return kAudioHardwareBadPropertySizeError;

            CFStringRef theUID = *((const CFStringRef*)inQualifierData);
            AudioObjectID theAnswer = kAudioObjectUnknown;
            for(UInt32 theIndex = 0; theIndex < 2; ++theIndex)
            {
                if(CFEqual(theUID, gDevices[theIndex].mUID)) theAnswer = gDevices[theIndex].mDeviceID;
            }
            *((AudioObjectID*)outData) = theAnswer;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        //  An empty path means the plug-in bundle itself supplies localised strings and resources.
        case kAudioPlugInPropertyResourceBundle:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(CFSTR("")));

        case kAudioObjectPropertyCustomPropertyInfoList:
        {
            AudioServerPlugInCustomPropertyInfo theInfo =
            {
                kPlugInCustomProperty_Version,
                kAudioServerPlugInCustomPropertyDataTypeCFString,
                kAudioServerPlugInCustomPropertyDataTypeNone
            };
            return ReturnArray(&theInfo, sizeof(theInfo), 1, inDataSize, outDataSize, outData);
        }

        case kPlugInCustomProperty_Version:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kDriverVersion));

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Box object properties

static OSStatus Box_GetProperty(const AudioObjectPropertyAddress* inAddress,
                                UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            RETURN_SCALAR(AudioClassID, kAudioObjectClassID);

        case kAudioObjectPropertyClass:
            RETURN_SCALAR(AudioClassID, kAudioBoxClassID);

        case kAudioObjectPropertyOwner:
            RETURN_SCALAR(AudioObjectID, kAudioObjectPlugInObject);

        case kAudioObjectPropertyName:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(CFSTR("Mixanimo")));

        case kAudioObjectPropertyModelName:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(CFSTR("Mixanimo Virtual Box")));

        case kAudioObjectPropertyManufacturer:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kManufacturer));

        case kAudioObjectPropertyOwnedObjects:
            return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);

        case kAudioObjectPropertyIdentify:
            RETURN_SCALAR(UInt32, 0);

        case kAudioObjectPropertySerialNumber:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(CFSTR("0")));

        case kAudioObjectPropertyFirmwareVersion:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kDriverVersion));

        case kAudioBoxPropertyBoxUID:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kBoxUID));

        case kAudioBoxPropertyTransportType:
            RETURN_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);

        case kAudioBoxPropertyHasAudio:
            RETURN_SCALAR(UInt32, 1);

        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquisitionFailed:
            RETURN_SCALAR(UInt32, 0);

        case kAudioBoxPropertyAcquired:
            RETURN_SCALAR(UInt32, gBoxAcquired);

        case kAudioBoxPropertyDeviceList:
        {
            AudioObjectID theList[] = { kObjectID_Device_Out, kObjectID_Device_Mic };
            return ReturnArray(theList, sizeof(AudioObjectID), (gBoxAcquired != 0) ? 2 : 0,
                               inDataSize, outDataSize, outData);
        }

        case kAudioBoxPropertyClockDeviceList:
            return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Device object properties

static OSStatus Device_GetProperty(const DeviceState* inDevice, const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    Boolean theHasControls = (inDevice->mVolumeID != kAudioObjectUnknown);
    Boolean theControlScope = theHasControls && (inAddress->mScope == kAudioObjectPropertyScopeOutput) &&
                              (inAddress->mElement == kAudioObjectPropertyElementMain);

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            RETURN_SCALAR(AudioClassID, kAudioObjectClassID);

        case kAudioObjectPropertyClass:
            RETURN_SCALAR(AudioClassID, kAudioDeviceClassID);

        case kAudioObjectPropertyOwner:
            RETURN_SCALAR(AudioObjectID, kAudioObjectPlugInObject);

        case kAudioObjectPropertyName:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(inDevice->mName));

        case kAudioObjectPropertyManufacturer:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kManufacturer));

        case kAudioObjectPropertyOwnedObjects:
        {
            AudioObjectID theList[4];
            UInt32 theCount = 0;
            if(inAddress->mScope != kAudioObjectPropertyScopeOutput) theList[theCount++] = inDevice->mInputStreamID;
            if(inAddress->mScope != kAudioObjectPropertyScopeInput) theList[theCount++] = inDevice->mOutputStreamID;
            if(theHasControls && (inAddress->mScope != kAudioObjectPropertyScopeInput))
            {
                theList[theCount++] = inDevice->mVolumeID;
                theList[theCount++] = inDevice->mMuteID;
            }
            return ReturnArray(theList, sizeof(AudioObjectID), theCount, inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyStreams:
        {
            AudioObjectID theList[] = { inDevice->mInputStreamID, inDevice->mOutputStreamID };
            const AudioObjectID* theSource = theList;
            if(inAddress->mScope == kAudioObjectPropertyScopeOutput) theSource = &theList[1];
            return ReturnArray(theSource, sizeof(AudioObjectID), StreamCountForScope(inAddress->mScope),
                               inDataSize, outDataSize, outData);
        }

        case kAudioObjectPropertyControlList:
        {
            AudioObjectID theList[] = { inDevice->mVolumeID, inDevice->mMuteID };
            return ReturnArray(theList, sizeof(AudioObjectID), theHasControls ? 2 : 0,
                               inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyDeviceUID:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(inDevice->mUID));

        case kAudioDevicePropertyModelUID:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(inDevice->mModelUID));

        case kAudioDevicePropertyTransportType:
            RETURN_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);

        case kAudioDevicePropertyRelatedDevices:
        {
            AudioObjectID theDevice = inDevice->mDeviceID;
            return ReturnArray(&theDevice, sizeof(AudioObjectID), 1, inDataSize, outDataSize, outData);
        }

        //  Zero means this device shares its clock with nothing else.
        case kAudioDevicePropertyClockDomain:
            RETURN_SCALAR(UInt32, 0);

        case kAudioDevicePropertyDeviceIsAlive:
            RETURN_SCALAR(UInt32, 1);

        case kAudioDevicePropertyDeviceIsRunning:
            RETURN_SCALAR(UInt32, (inDevice->mIOCount > 0) ? 1 : 0);

        //  Each device offers itself for one direction only, so the other direction never becomes
        //  a default and the system keeps its real device there.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RETURN_SCALAR(UInt32, (inAddress->mScope == inDevice->mDefaultScope) ? 1 : 0);

        case kAudioDevicePropertyIsHidden:
            RETURN_SCALAR(UInt32, (gAppProcessCount > 0) ? 0 : 1);

        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            RETURN_SCALAR(UInt32, 0);

        case kAudioDevicePropertyZeroTimeStampPeriod:
            RETURN_SCALAR(UInt32, kZeroTimeStampPeriod);

        case kAudioDevicePropertyNominalSampleRate:
            RETURN_SCALAR(Float64, inDevice->mSampleRate);

        case kAudioDevicePropertyAvailableNominalSampleRates:
        {
            AudioValueRange theRanges[6];
            for(UInt32 theIndex = 0; theIndex < inDevice->mRateCount; ++theIndex)
            {
                theRanges[theIndex].mMinimum = inDevice->mRates[theIndex];
                theRanges[theIndex].mMaximum = inDevice->mRates[theIndex];
            }
            return ReturnArray(theRanges, sizeof(AudioValueRange), inDevice->mRateCount,
                               inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyIcon:
        {
            CFURLRef theURL = CopyIconURL();
            if(theURL == NULL) return kAudioHardwareUnknownPropertyError;
            if(outData == NULL) { CFRelease(theURL); *outDataSize = sizeof(CFURLRef); return 0; }
            if(inDataSize < sizeof(CFURLRef)) { CFRelease(theURL); return kAudioHardwareBadPropertySizeError; }
            *((CFURLRef*)outData) = theURL;
            *outDataSize = sizeof(CFURLRef);
            return 0;
        }

        case kAudioDevicePropertyPreferredChannelsForStereo:
        {
            UInt32 thePair[] = { 1, (inDevice->mChannels > 1) ? 2 : 1 };
            return ReturnArray(thePair, sizeof(UInt32), 2, inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyPreferredChannelLayout:
        {
            UInt32 theSize = offsetof(AudioChannelLayout, mChannelDescriptions) +
                             (inDevice->mChannels * sizeof(AudioChannelDescription));
            if(outData != NULL)
            {
                if(inDataSize < theSize) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* theLayout = (AudioChannelLayout*)outData;
                memset(theLayout, 0, theSize);
                theLayout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                theLayout->mNumberChannelDescriptions = inDevice->mChannels;
                theLayout->mChannelDescriptions[0].mChannelLabel =
                    (inDevice->mChannels > 1) ? kAudioChannelLabel_Left : kAudioChannelLabel_Mono;
                if(inDevice->mChannels > 1)
                {
                    theLayout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                }
            }
            *outDataSize = theSize;
            return 0;
        }

        case kAudioDevicePropertyStreamConfiguration:
        {
            UInt32 theStreams = StreamCountForScope(inAddress->mScope);
            UInt32 theSize = offsetof(AudioBufferList, mBuffers) + (theStreams * sizeof(AudioBuffer));
            if(outData != NULL)
            {
                if(inDataSize < theSize) return kAudioHardwareBadPropertySizeError;
                AudioBufferList* theList = (AudioBufferList*)outData;
                memset(theList, 0, theSize);
                theList->mNumberBuffers = theStreams;
                for(UInt32 theIndex = 0; theIndex < theStreams; ++theIndex)
                {
                    theList->mBuffers[theIndex].mNumberChannels = inDevice->mChannels;
                }
            }
            *outDataSize = theSize;
            return 0;
        }

        //  The device level volume and mute mirror the controls, which is where the Mac's volume
        //  keys and menu bar slider look first.
        case kAudioDevicePropertyVolumeScalar:
            if(!theControlScope) return kAudioHardwareUnknownPropertyError;
            RETURN_SCALAR(Float32, inDevice->mVolumeScalar);

        case kAudioDevicePropertyVolumeDecibels:
            if(!theControlScope) return kAudioHardwareUnknownPropertyError;
            RETURN_SCALAR(Float32, ScalarToDecibel(inDevice->mVolumeScalar));

        case kAudioDevicePropertyVolumeRangeDecibels:
        {
            if(!theControlScope) return kAudioHardwareUnknownPropertyError;
            AudioValueRange theRange = { kVolumeMinDB, kVolumeMaxDB };
            RETURN_SCALAR(AudioValueRange, theRange);
        }

        case kAudioDevicePropertyVolumeScalarToDecibels:
            if(!theControlScope) return kAudioHardwareUnknownPropertyError;
            RETURN_CONVERTED(ScalarToDecibel(theArgument));

        case kAudioDevicePropertyVolumeDecibelsToScalar:
            if(!theControlScope) return kAudioHardwareUnknownPropertyError;
            RETURN_CONVERTED(DecibelToScalar(theArgument));

        case kAudioDevicePropertyMute:
            if(!theControlScope) return kAudioHardwareUnknownPropertyError;
            RETURN_SCALAR(UInt32, inDevice->mMute);

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Stream object properties

static OSStatus Stream_GetProperty(const DeviceState* inDevice, AudioObjectID inObjectID,
                                   const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    Boolean theIsInput = (inObjectID == inDevice->mInputStreamID);

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            RETURN_SCALAR(AudioClassID, kAudioObjectClassID);

        case kAudioObjectPropertyClass:
            RETURN_SCALAR(AudioClassID, kAudioStreamClassID);

        case kAudioObjectPropertyOwner:
            RETURN_SCALAR(AudioObjectID, inDevice->mDeviceID);

        case kAudioObjectPropertyOwnedObjects:
            return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);

        case kAudioStreamPropertyIsActive:
            RETURN_SCALAR(UInt32, theIsInput ? inDevice->mInputStreamActive : inDevice->mOutputStreamActive);

        //  Zero marks an output stream, one an input stream.
        case kAudioStreamPropertyDirection:
            RETURN_SCALAR(UInt32, theIsInput ? 1 : 0);

        case kAudioStreamPropertyTerminalType:
            RETURN_SCALAR(UInt32, theIsInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);

        case kAudioStreamPropertyStartingChannel:
            RETURN_SCALAR(UInt32, 1);

        case kAudioStreamPropertyLatency:
            RETURN_SCALAR(UInt32, 0);

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        {
            if(outData != NULL)
            {
                if(inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
                FillFormat(inDevice, (AudioStreamBasicDescription*)outData);
            }
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        {
            AudioStreamRangedDescription theRanged[6];
            for(UInt32 theIndex = 0; theIndex < inDevice->mRateCount; ++theIndex)
            {
                memset(&theRanged[theIndex], 0, sizeof(AudioStreamRangedDescription));
                FillFormat(inDevice, &theRanged[theIndex].mFormat);
                theRanged[theIndex].mFormat.mSampleRate = inDevice->mRates[theIndex];
                theRanged[theIndex].mSampleRateRange.mMinimum = inDevice->mRates[theIndex];
                theRanged[theIndex].mSampleRateRange.mMaximum = inDevice->mRates[theIndex];
            }
            return ReturnArray(theRanged, sizeof(AudioStreamRangedDescription), inDevice->mRateCount,
                               inDataSize, outDataSize, outData);
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Control object properties

static OSStatus Control_GetProperty(const DeviceState* inDevice, AudioObjectID inObjectID,
                                    const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    Boolean theIsVolume = (inObjectID == inDevice->mVolumeID);

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            RETURN_SCALAR(AudioClassID, theIsVolume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);

        case kAudioObjectPropertyClass:
            RETURN_SCALAR(AudioClassID, theIsVolume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);

        case kAudioObjectPropertyOwner:
            RETURN_SCALAR(AudioObjectID, inDevice->mDeviceID);

        case kAudioObjectPropertyOwnedObjects:
            return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);

        case kAudioControlPropertyScope:
            RETURN_SCALAR(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);

        case kAudioControlPropertyElement:
            RETURN_SCALAR(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);

        case kAudioLevelControlPropertyScalarValue:
            if(!theIsVolume) return kAudioHardwareUnknownPropertyError;
            RETURN_SCALAR(Float32, inDevice->mVolumeScalar);

        case kAudioLevelControlPropertyDecibelValue:
            if(!theIsVolume) return kAudioHardwareUnknownPropertyError;
            RETURN_SCALAR(Float32, ScalarToDecibel(inDevice->mVolumeScalar));

        case kAudioLevelControlPropertyDecibelRange:
        {
            if(!theIsVolume) return kAudioHardwareUnknownPropertyError;
            AudioValueRange theRange = { kVolumeMinDB, kVolumeMaxDB };
            RETURN_SCALAR(AudioValueRange, theRange);
        }

        case kAudioLevelControlPropertyConvertScalarToDecibels:
            if(!theIsVolume) return kAudioHardwareUnknownPropertyError;
            RETURN_CONVERTED(ScalarToDecibel(theArgument));

        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if(!theIsVolume) return kAudioHardwareUnknownPropertyError;
            RETURN_CONVERTED(DecibelToScalar(theArgument));

        case kAudioBooleanControlPropertyValue:
            if(theIsVolume) return kAudioHardwareUnknownPropertyError;
            RETURN_SCALAR(UInt32, inDevice->mMute);

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Property dispatch

//  Single entry point for both the size and the data queries; outData NULL asks for the size only.
static OSStatus GetProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress,
                            UInt32 inQualifierDataSize, const void* inQualifierData,
                            UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    OSStatus theError;

    if((inAddress == NULL) || (outDataSize == NULL)) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gStateMutex);
    if(inObjectID == kAudioObjectPlugInObject)
    {
        theError = PlugIn_GetProperty(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
    }
    else if(inObjectID == kObjectID_Box)
    {
        theError = Box_GetProperty(inAddress, inDataSize, outDataSize, outData);
    }
    else
    {
        const DeviceState* theDevice = DeviceForObjectID(inObjectID);
        if(theDevice == NULL)
        {
            theError = kAudioHardwareBadObjectError;
        }
        else if(inObjectID == theDevice->mDeviceID)
        {
            theError = Device_GetProperty(theDevice, inAddress, inDataSize, outDataSize, outData);
        }
        else if((inObjectID == theDevice->mInputStreamID) || (inObjectID == theDevice->mOutputStreamID))
        {
            theError = Stream_GetProperty(theDevice, inObjectID, inAddress, inDataSize, outDataSize, outData);
        }
        else
        {
            theError = Control_GetProperty(theDevice, inObjectID, inAddress, inDataSize, outDataSize, outData);
        }
    }
    pthread_mutex_unlock(&gStateMutex);

    return theError;
}

#pragma mark - Ring buffer

//  Called from the IO thread only: no allocation, no lock, every index masked into the ring.

//  Writers add into the ring so several client processes mix, except for the writer that opens a
//  span, which overwrites it. Without that, a span nobody reads would keep growing across wraps.
static void RingWrite(DeviceState* inDevice, UInt64 inStart, UInt32 inFrames, const Float32* inSource)
{
    if((inSource == NULL) || (inFrames == 0) || (inFrames > kRingFrames)) return;

    UInt64 thePreviousEnd = atomic_load_explicit(&inDevice->mWriteEnd, memory_order_relaxed);
    Boolean theOpensSpan = (inStart >= thePreviousEnd);
    if(theOpensSpan)
    {
        atomic_store_explicit(&inDevice->mWriteEnd, inStart + inFrames, memory_order_relaxed);
    }

    UInt32 theChannels = inDevice->mChannels;
    UInt32 theOffset = (UInt32)(inStart & (kRingFrames - 1));
    UInt32 theHead = ((theOffset + inFrames) > kRingFrames) ? (kRingFrames - theOffset) : inFrames;
    size_t theHeadSamples = (size_t)theHead * theChannels;
    size_t theTailSamples = (size_t)(inFrames - theHead) * theChannels;
    Float32* theRing = inDevice->mRing + ((size_t)theOffset * theChannels);

    if(theOpensSpan)
    {
        memcpy(theRing, inSource, theHeadSamples * sizeof(Float32));
        memcpy(inDevice->mRing, inSource + theHeadSamples, theTailSamples * sizeof(Float32));
    }
    else
    {
        for(size_t theSample = 0; theSample < theHeadSamples; ++theSample)
        {
            theRing[theSample] += inSource[theSample];
        }
        for(size_t theSample = 0; theSample < theTailSamples; ++theSample)
        {
            inDevice->mRing[theSample] += inSource[theHeadSamples + theSample];
        }
    }
}

//  Reading empties what it took, so silence follows a writer that stops.
static void RingRead(DeviceState* inDevice, UInt64 inStart, UInt32 inFrames, Float32* outDestination)
{
    if((outDestination == NULL) || (inFrames == 0)) return;

    UInt32 theChannels = inDevice->mChannels;
    if(inFrames > kRingFrames)
    {
        memset(outDestination, 0, (size_t)inFrames * theChannels * sizeof(Float32));
        return;
    }

    UInt32 theOffset = (UInt32)(inStart & (kRingFrames - 1));
    UInt32 theHead = ((theOffset + inFrames) > kRingFrames) ? (kRingFrames - theOffset) : inFrames;
    size_t theHeadBytes = (size_t)theHead * theChannels * sizeof(Float32);
    size_t theTailBytes = (size_t)(inFrames - theHead) * theChannels * sizeof(Float32);
    Float32* theRing = inDevice->mRing + ((size_t)theOffset * theChannels);

    memcpy(outDestination, theRing, theHeadBytes);
    memset(theRing, 0, theHeadBytes);
    if(theTailBytes > 0)
    {
        memcpy(((UInt8*)outDestination) + theHeadBytes, inDevice->mRing, theTailBytes);
        memset(inDevice->mRing, 0, theTailBytes);
    }
}

#pragma mark - Hidden state

//  Returns true when the count of attached app processes crossed zero, which changes hidden.
static Boolean TrackAppClient(const AudioServerPlugInClientInfo* inClientInfo, Boolean inAttaching)
{
    if((inClientInfo == NULL) || (inClientInfo->mBundleID == NULL)) return false;
    if(!CFEqual(inClientInfo->mBundleID, kAppBundleID)) return false;

    UInt32 theBefore = gAppProcessCount;
    UInt32 theFree = kMaxAppProcesses;

    for(UInt32 theIndex = 0; theIndex < kMaxAppProcesses; ++theIndex)
    {
        if(gAppRefs[theIndex] == 0)
        {
            if(theFree == kMaxAppProcesses) theFree = theIndex;
        }
        else if(gAppPIDs[theIndex] == inClientInfo->mProcessID)
        {
            if(inAttaching)
            {
                ++gAppRefs[theIndex];
            }
            else if(--gAppRefs[theIndex] == 0)
            {
                --gAppProcessCount;
            }
            return gAppProcessCount != theBefore;
        }
    }

    if(inAttaching && (theFree < kMaxAppProcesses))
    {
        gAppPIDs[theFree] = inClientInfo->mProcessID;
        gAppRefs[theFree] = 1;
        ++gAppProcessCount;
    }
    return gAppProcessCount != theBefore;
}

static void NotifyHiddenChanged(AudioServerPlugInHostRef inHost)
{
    if(inHost == NULL) return;
    AudioObjectPropertyAddress theAddress =
        { kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    for(UInt32 theIndex = 0; theIndex < 2; ++theIndex)
    {
        inHost->PropertiesChanged(inHost, gDevices[theIndex].mDeviceID, 1, &theAddress);
    }
}

#pragma mark - Driver interface: administration

static OSStatus Mixanimo_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    mach_timebase_info_data_t theTimeBase;
    mach_timebase_info(&theTimeBase);

    pthread_mutex_lock(&gStateMutex);
    gHost = inHost;
    gHostTicksPerSecond = 1.0e9 * ((Float64)theTimeBase.denom / (Float64)theTimeBase.numer);
    for(UInt32 theIndex = 0; theIndex < 2; ++theIndex)
    {
        atomic_store(&gDevices[theIndex].mHostTicksPerPeriod,
                     (gHostTicksPerSecond / gDevices[theIndex].mSampleRate) * (Float64)kZeroTimeStampPeriod);
    }
    pthread_mutex_unlock(&gStateMutex);

    os_log(OS_LOG_DEFAULT, "Mixanimo: driver initialised, version %@", kDriverVersion);
    return 0;
}

static OSStatus Mixanimo_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                      const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Mixanimo_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

//  The HAL calls this once per client process per device, when that process first asks the device
//  for anything, not only when it creates an IOProc: a plain property read attaches the client too.
static OSStatus Mixanimo_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    if((theDevice == NULL) || (inDeviceObjectID != theDevice->mDeviceID)) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    Boolean theHiddenChanged = TrackAppClient(inClientInfo, true);
    AudioServerPlugInHostRef theHost = gHost;
    UInt32 theProcesses = gAppProcessCount;
    pthread_mutex_unlock(&gStateMutex);

    os_log(OS_LOG_DEFAULT, "Mixanimo: AddDeviceClient device %u pid %d bundle %{public}@ apps %u",
           (unsigned)inDeviceObjectID, (inClientInfo != NULL) ? inClientInfo->mProcessID : 0,
           ((inClientInfo != NULL) && (inClientInfo->mBundleID != NULL)) ? inClientInfo->mBundleID : CFSTR("(none)"),
           (unsigned)theProcesses);

    if(theHiddenChanged) NotifyHiddenChanged(theHost);
    return 0;
}

static OSStatus Mixanimo_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                            const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    if((theDevice == NULL) || (inDeviceObjectID != theDevice->mDeviceID)) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    Boolean theHiddenChanged = TrackAppClient(inClientInfo, false);
    AudioServerPlugInHostRef theHost = gHost;
    UInt32 theProcesses = gAppProcessCount;
    pthread_mutex_unlock(&gStateMutex);

    os_log(OS_LOG_DEFAULT, "Mixanimo: RemoveDeviceClient device %u pid %d apps %u",
           (unsigned)inDeviceObjectID, (inClientInfo != NULL) ? inClientInfo->mProcessID : 0,
           (unsigned)theProcesses);

    if(theHiddenChanged) NotifyHiddenChanged(theHost);
    return 0;
}

//  The host stops IO around this call, so the new rate, the stream formats derived from it and the
//  zero time stamp anchor all move together.
static OSStatus Mixanimo_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                          UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inChangeInfo;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    if((theDevice == NULL) || (inDeviceObjectID != theDevice->mDeviceID)) return kAudioHardwareBadObjectError;

    Boolean theKnownRate = false;
    for(UInt32 theIndex = 0; theIndex < theDevice->mRateCount; ++theIndex)
    {
        if((Float64)inChangeAction == theDevice->mRates[theIndex]) theKnownRate = true;
    }
    if(!theKnownRate) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gStateMutex);
    theDevice->mSampleRate = (Float64)inChangeAction;
    atomic_store(&theDevice->mHostTicksPerPeriod,
                 (gHostTicksPerSecond / theDevice->mSampleRate) * (Float64)kZeroTimeStampPeriod);
    atomic_store(&theDevice->mAnchorHostTime, mach_absolute_time());
    atomic_store(&theDevice->mTimeStampCount, 0);
    atomic_store(&theDevice->mWriteEnd, 0);
    memset(theDevice->mRing, 0, (size_t)kRingFrames * theDevice->mChannels * sizeof(Float32));
    pthread_mutex_unlock(&gStateMutex);

    os_log(OS_LOG_DEFAULT, "Mixanimo: device %u now at %llu Hz", (unsigned)inDeviceObjectID, inChangeAction);
    return 0;
}

static OSStatus Mixanimo_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                        UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inChangeAction; (void)inChangeInfo;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    return ((theDevice != NULL) && (inDeviceObjectID == theDevice->mDeviceID)) ? 0 : kAudioHardwareBadObjectError;
}

#pragma mark - Driver interface: properties

static Boolean Mixanimo_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress)
{
    (void)inDriver; (void)inClientProcessID;
    UInt32 theSize = 0;
    return GetProperty(inObjectID, inAddress, 0, NULL, 0, &theSize, NULL) == 0;
}

static OSStatus Mixanimo_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                            pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                            Boolean* outIsSettable)
{
    (void)inDriver; (void)inClientProcessID;
    if(outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    UInt32 theSize = 0;
    OSStatus theError = GetProperty(inObjectID, inAddress, 0, NULL, 0, &theSize, NULL);
    if(theError != 0) return theError;

    const DeviceState* theDevice = DeviceForObjectID(inObjectID);

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyIdentify:
        case kAudioBoxPropertyAcquired:
            *outIsSettable = (inObjectID == kObjectID_Box);
            break;

        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyVolumeScalar:
        case kAudioDevicePropertyVolumeDecibels:
        case kAudioDevicePropertyMute:
            *outIsSettable = (theDevice != NULL) && (inObjectID == theDevice->mDeviceID);
            break;

        case kAudioStreamPropertyIsActive:
            *outIsSettable = (theDevice != NULL) &&
                             ((inObjectID == theDevice->mInputStreamID) || (inObjectID == theDevice->mOutputStreamID));
            break;

        case kAudioLevelControlPropertyScalarValue:
        case kAudioLevelControlPropertyDecibelValue:
        case kAudioBooleanControlPropertyValue:
            *outIsSettable = true;
            break;

        default:
            *outIsSettable = false;
            break;
    }

    return 0;
}

static OSStatus Mixanimo_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                             pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                             UInt32 inQualifierDataSize, const void* inQualifierData,
                                             UInt32* outDataSize)
{
    (void)inDriver; (void)inClientProcessID;
    return GetProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL);
}

static OSStatus Mixanimo_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                         pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                         UInt32 inQualifierDataSize, const void* inQualifierData,
                                         UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    (void)inDriver; (void)inClientProcessID;
    if(outData == NULL) return kAudioHardwareIllegalOperationError;
    return GetProperty(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
}

//  Stores the new volume or mute and returns what the host must be told about; the driver never
//  applies either to the audio, the app does.
static UInt32 SetControlValue(DeviceState* inDevice, AudioObjectPropertySelector inSelector,
                              UInt32 inDataSize, const void* inData,
                              AudioObjectPropertyAddress* outChanged, OSStatus* outError)
{
    switch(inSelector)
    {
        case kAudioDevicePropertyVolumeScalar:
        case kAudioLevelControlPropertyScalarValue:
        case kAudioDevicePropertyVolumeDecibels:
        case kAudioLevelControlPropertyDecibelValue:
        {
            if(inDataSize != sizeof(Float32)) { *outError = kAudioHardwareBadPropertySizeError; return 0; }
            Float32 theValue = *((const Float32*)inData);
            Boolean theIsScalar = (inSelector == kAudioDevicePropertyVolumeScalar) ||
                                  (inSelector == kAudioLevelControlPropertyScalarValue);
            if(theIsScalar)
            {
                inDevice->mVolumeScalar = (theValue < 0.0f) ? 0.0f : ((theValue > 1.0f) ? 1.0f : theValue);
            }
            else
            {
                inDevice->mVolumeScalar = DecibelToScalar(theValue);
            }
            outChanged[0] = (AudioObjectPropertyAddress){ kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            outChanged[1] = (AudioObjectPropertyAddress){ kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            return 2;
        }

        case kAudioDevicePropertyMute:
        case kAudioBooleanControlPropertyValue:
        {
            if(inDataSize != sizeof(UInt32)) { *outError = kAudioHardwareBadPropertySizeError; return 0; }
            inDevice->mMute = (*((const UInt32*)inData) != 0) ? 1 : 0;
            outChanged[0] = (AudioObjectPropertyAddress){ kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            return 1;
        }

        default:
            *outError = kAudioHardwareUnknownPropertyError;
            return 0;
    }
}

static OSStatus Mixanimo_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                         pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                         UInt32 inQualifierDataSize, const void* inQualifierData,
                                         UInt32 inDataSize, const void* inData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    if((inAddress == NULL) || (inData == NULL)) return kAudioHardwareIllegalOperationError;

    //  Collected inside the lock and sent to the host outside it.
    AudioObjectPropertyAddress theChanged[2];
    AudioObjectID theChangedObject = inObjectID;
    UInt32 theChangedCount = 0;
    Boolean theBoxListChanged = false;
    Float64 theRequestedRate = 0.0;
    OSStatus theError = 0;

    pthread_mutex_lock(&gStateMutex);
    DeviceState* theDevice = DeviceForObjectID(inObjectID);

    if(inObjectID == kObjectID_Box)
    {
        if(inAddress->mSelector == kAudioObjectPropertyIdentify)
        {
            //  Nothing to flash on a virtual box.
        }
        else if(inAddress->mSelector == kAudioBoxPropertyAcquired)
        {
            if(inDataSize != sizeof(UInt32))
            {
                theError = kAudioHardwareBadPropertySizeError;
            }
            else
            {
                UInt32 theNew = (*((const UInt32*)inData) != 0) ? 1 : 0;
                if(theNew != gBoxAcquired)
                {
                    gBoxAcquired = theNew;
                    theChanged[0] = (AudioObjectPropertyAddress){ kAudioBoxPropertyAcquired, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                    theChanged[1] = (AudioObjectPropertyAddress){ kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                    theChangedCount = 2;
                    theBoxListChanged = true;
                }
            }
        }
        else
        {
            theError = kAudioHardwareUnknownPropertyError;
        }
    }
    else if(theDevice == NULL)
    {
        theError = kAudioHardwareBadObjectError;
    }
    else if(inObjectID == theDevice->mDeviceID)
    {
        if(inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
        {
            if(inDataSize != sizeof(Float64))
            {
                theError = kAudioHardwareBadPropertySizeError;
            }
            else
            {
                Float64 theRate = *((const Float64*)inData);
                theError = kAudioHardwareIllegalOperationError;
                for(UInt32 theIndex = 0; theIndex < theDevice->mRateCount; ++theIndex)
                {
                    if(theRate == theDevice->mRates[theIndex]) theError = 0;
                }
                if((theError == 0) && (theRate != theDevice->mSampleRate)) theRequestedRate = theRate;
            }
        }
        else if(theDevice->mVolumeID == kAudioObjectUnknown)
        {
            theError = kAudioHardwareUnknownPropertyError;
        }
        else
        {
            theChangedCount = SetControlValue(theDevice, inAddress->mSelector, inDataSize, inData, theChanged, &theError);
            theChangedObject = (inAddress->mSelector == kAudioDevicePropertyMute) ? theDevice->mMuteID : theDevice->mVolumeID;
        }
    }
    else if((inObjectID == theDevice->mInputStreamID) || (inObjectID == theDevice->mOutputStreamID))
    {
        if(inAddress->mSelector != kAudioStreamPropertyIsActive)
        {
            theError = kAudioHardwareUnknownPropertyError;
        }
        else if(inDataSize != sizeof(UInt32))
        {
            theError = kAudioHardwareBadPropertySizeError;
        }
        else
        {
            UInt32 theNew = (*((const UInt32*)inData) != 0) ? 1 : 0;
            if(inObjectID == theDevice->mInputStreamID) theDevice->mInputStreamActive = theNew;
            else theDevice->mOutputStreamActive = theNew;
        }
    }
    else
    {
        theChangedCount = SetControlValue(theDevice, inAddress->mSelector, inDataSize, inData, theChanged, &theError);
    }

    AudioServerPlugInHostRef theHost = gHost;
    pthread_mutex_unlock(&gStateMutex);

    if(theHost == NULL) return theError;

    if(theRequestedRate > 0.0)
    {
        theHost->RequestDeviceConfigurationChange(theHost, inObjectID, (UInt64)theRequestedRate, NULL);
    }

    if(theChangedCount > 0)
    {
        theHost->PropertiesChanged(theHost, theChangedObject, theChangedCount, theChanged);
    }

    if(theBoxListChanged)
    {
        AudioObjectPropertyAddress theDeviceList = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        theHost->PropertiesChanged(theHost, kAudioObjectPlugInObject, 1, &theDeviceList);
    }

    return theError;
}

#pragma mark - Driver interface: IO

static OSStatus Mixanimo_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    if((theDevice == NULL) || (inDeviceObjectID != theDevice->mDeviceID)) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if(theDevice->mIOCount == 0)
    {
        atomic_store(&theDevice->mAnchorHostTime, mach_absolute_time());
        atomic_store(&theDevice->mTimeStampCount, 0);
        atomic_store(&theDevice->mWriteEnd, 0);
        memset(theDevice->mRing, 0, (size_t)kRingFrames * theDevice->mChannels * sizeof(Float32));
    }
    ++theDevice->mIOCount;
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

static OSStatus Mixanimo_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    if((theDevice == NULL) || (inDeviceObjectID != theDevice->mDeviceID)) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if(theDevice->mIOCount > 0) --theDevice->mIOCount;
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

//  The device has no hardware clock, so the host clock paces it one time stamp period at a time.
static OSStatus Mixanimo_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inDriver; (void)inClientID;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    if((theDevice == NULL) || (inDeviceObjectID != theDevice->mDeviceID)) return kAudioHardwareBadObjectError;

    UInt64 theAnchor = atomic_load(&theDevice->mAnchorHostTime);
    Float64 theTicks = atomic_load(&theDevice->mHostTicksPerPeriod);
    UInt64 theCount = atomic_load(&theDevice->mTimeStampCount);

    if(mach_absolute_time() >= (theAnchor + (UInt64)(((Float64)(theCount + 1)) * theTicks)))
    {
        ++theCount;
        atomic_store(&theDevice->mTimeStampCount, theCount);
    }

    *outSampleTime = (Float64)(theCount * kZeroTimeStampPeriod);
    *outHostTime = theAnchor + (UInt64)(((Float64)theCount) * theTicks);
    *outSeed = 1;
    return 0;
}

static OSStatus Mixanimo_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                           UInt32 inClientID, UInt32 inOperationID,
                                           Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inClientID;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    if((theDevice == NULL) || (inDeviceObjectID != theDevice->mDeviceID)) return kAudioHardwareBadObjectError;

    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationWriteMix) ||
                 (inOperationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return 0;
}

static OSStatus Mixanimo_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    return ((theDevice != NULL) && (inDeviceObjectID == theDevice->mDeviceID)) ? 0 : kAudioHardwareBadObjectError;
}

//  Realtime path. It reads only immutable fields of the device and its atomics, so nothing here
//  allocates, locks or waits. The host places the input time behind the output time by a whole IO
//  buffer plus the safety offsets this device reports, which is what keeps a read behind its write.
static OSStatus Mixanimo_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                       void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;

    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    if((theDevice == NULL) || (inDeviceObjectID != theDevice->mDeviceID)) return kAudioHardwareBadObjectError;
    if(inIOCycleInfo == NULL) return 0;

    if(inOperationID == kAudioServerPlugInIOOperationWriteMix)
    {
        Float64 theSampleTime = inIOCycleInfo->mOutputTime.mSampleTime;
        if(theSampleTime >= 0.0)
        {
            RingWrite(theDevice, (UInt64)theSampleTime, inIOBufferFrameSize, (const Float32*)ioMainBuffer);
        }
    }
    else if(inOperationID == kAudioServerPlugInIOOperationReadInput)
    {
        Float64 theSampleTime = inIOCycleInfo->mInputTime.mSampleTime;
        if(theSampleTime >= 0.0)
        {
            RingRead(theDevice, (UInt64)theSampleTime, inIOBufferFrameSize, (Float32*)ioMainBuffer);
        }
        else if(ioMainBuffer != NULL)
        {
            memset(ioMainBuffer, 0, (size_t)inIOBufferFrameSize * theDevice->mChannels * sizeof(Float32));
        }
    }

    return 0;
}

static OSStatus Mixanimo_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    DeviceState* theDevice = DeviceForObjectID(inDeviceObjectID);
    return ((theDevice != NULL) && (inDeviceObjectID == theDevice->mDeviceID)) ? 0 : kAudioHardwareBadObjectError;
}

#pragma mark - COM plumbing and factory

static HRESULT Mixanimo_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG Mixanimo_AddRef(void* inDriver);
static ULONG Mixanimo_Release(void* inDriver);

static AudioServerPlugInDriverInterface gInterface =
{
    NULL,
    Mixanimo_QueryInterface,
    Mixanimo_AddRef,
    Mixanimo_Release,
    Mixanimo_Initialize,
    Mixanimo_CreateDevice,
    Mixanimo_DestroyDevice,
    Mixanimo_AddDeviceClient,
    Mixanimo_RemoveDeviceClient,
    Mixanimo_PerformDeviceConfigurationChange,
    Mixanimo_AbortDeviceConfigurationChange,
    Mixanimo_HasProperty,
    Mixanimo_IsPropertySettable,
    Mixanimo_GetPropertyDataSize,
    Mixanimo_GetPropertyData,
    Mixanimo_SetPropertyData,
    Mixanimo_StartIO,
    Mixanimo_StopIO,
    Mixanimo_GetZeroTimeStamp,
    Mixanimo_WillDoIOOperation,
    Mixanimo_BeginIOOperation,
    Mixanimo_DoIOOperation,
    Mixanimo_EndIOOperation
};

static AudioServerPlugInDriverInterface*    gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef           gDriverRef = &gInterfacePtr;

//  The single interface lives for the life of the process, so the reference count is a formality.
static ULONG gRefCount = 1;

static HRESULT Mixanimo_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if((inDriver != gDriverRef) || (outInterface == NULL)) return E_INVALIDARG;

    CFUUIDRef theRequested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean theMatch = CFEqual(theRequested, IUnknownUUID) || CFEqual(theRequested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(theRequested);

    if(!theMatch) return E_NOINTERFACE;

    ++gRefCount;
    *outInterface = gDriverRef;
    return S_OK;
}

static ULONG Mixanimo_AddRef(void* inDriver)
{
    return (inDriver == gDriverRef) ? ++gRefCount : 0;
}

static ULONG Mixanimo_Release(void* inDriver)
{
    if(inDriver != gDriverRef) return 0;
    if(gRefCount > 1) --gRefCount;
    return gRefCount;
}

void* MixanimoDriverFactory(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    return ((inRequestedTypeUUID != NULL) && CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) ? gDriverRef : NULL;
}
