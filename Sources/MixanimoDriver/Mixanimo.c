//  AudioServerPlugIn that publishes one virtual stereo output device.
//  Loaded by coreaudiod from /Library/Audio/Plug-Ins/HAL/Mixanimo.driver.

#include "MixanimoDriver.h"

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>

#pragma mark - Configuration

#define kBoxUID         CFSTR("com.mixanimo.box")
#define kDeviceUID      CFSTR("com.mixanimo.output")
#define kModelUID       CFSTR("com.mixanimo.output.model")
#define kDeviceName     CFSTR("Mixanimo")
#define kManufacturer   CFSTR("Mixanimo")
#define kBundleID       CFSTR("com.mixanimo.driver")

enum
{
    kObjectID_Box       = 2,
    kObjectID_Device    = 3,
    kObjectID_Stream    = 4
};

static const Float64    kSampleRate     = 48000.0;
static const UInt32     kChannelCount   = 2;

//  Sample frames between successive zero time stamps; the host requires at least 10923.
static const UInt32     kRingBufferFrames = 16384;

#pragma mark - State

static pthread_mutex_t          gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32                   gBoxAcquired = 1;
static UInt32                   gStreamIsActive = 1;

//  IO state, guarded by gStateMutex outside the IO callback itself.
static UInt32   gIOClientCount = 0;
static UInt64   gAnchorHostTime = 0;
static UInt64   gTimeStampCount = 0;
static Float64  gHostTicksPerRingBuffer = 0.0;

#pragma mark - Helpers

static void FillFormat(AudioStreamBasicDescription* outFormat)
{
    outFormat->mSampleRate = kSampleRate;
    outFormat->mFormatID = kAudioFormatLinearPCM;
    outFormat->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket = 4 * kChannelCount;
    outFormat->mFramesPerPacket = 1;
    outFormat->mBytesPerFrame = 4 * kChannelCount;
    outFormat->mChannelsPerFrame = kChannelCount;
    outFormat->mBitsPerChannel = 32;
    outFormat->mReserved = 0;
}

//  The device has output streams only, so an input-scope query sees nothing.
static UInt32 StreamCountForScope(AudioObjectPropertyScope inScope)
{
    return ((inScope == kAudioObjectPropertyScopeGlobal) || (inScope == kAudioObjectPropertyScopeOutput)) ? 1 : 0;
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
            AudioObjectID theList[] = { kObjectID_Box, kObjectID_Device };
            UInt32 theCount = (gBoxAcquired != 0) ? 2 : 1;
            return ReturnArray(theList, sizeof(AudioObjectID), theCount, inDataSize, outDataSize, outData);
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
            AudioObjectID theDevice = kObjectID_Device;
            return ReturnArray(&theDevice, sizeof(AudioObjectID), (gBoxAcquired != 0) ? 1 : 0, inDataSize, outDataSize, outData);
        }

        case kAudioPlugInPropertyTranslateUIDToDevice:
        {
            if(outData == NULL) { *outDataSize = sizeof(AudioObjectID); return 0; }
            if(inDataSize < sizeof(AudioObjectID)) return kAudioHardwareBadPropertySizeError;
            if((inQualifierData == NULL) || (inQualifierDataSize != sizeof(CFStringRef))) return kAudioHardwareBadPropertySizeError;
            *((AudioObjectID*)outData) = CFEqual(*((const CFStringRef*)inQualifierData), kDeviceUID) ? kObjectID_Device : kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            return 0;
        }

        //  An empty path means the plug-in bundle itself supplies localised strings and resources.
        case kAudioPlugInPropertyResourceBundle:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(CFSTR("")));

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
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kDeviceName));

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
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(CFSTR("0.1.0")));

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
            AudioObjectID theDevice = kObjectID_Device;
            return ReturnArray(&theDevice, sizeof(AudioObjectID), (gBoxAcquired != 0) ? 1 : 0, inDataSize, outDataSize, outData);
        }

        case kAudioBoxPropertyClockDeviceList:
            return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Device object properties

static OSStatus Device_GetProperty(const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            RETURN_SCALAR(AudioClassID, kAudioObjectClassID);

        case kAudioObjectPropertyClass:
            RETURN_SCALAR(AudioClassID, kAudioDeviceClassID);

        case kAudioObjectPropertyOwner:
            RETURN_SCALAR(AudioObjectID, kAudioObjectPlugInObject);

        case kAudioObjectPropertyName:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kDeviceName));

        case kAudioObjectPropertyManufacturer:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kManufacturer));

        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
        {
            AudioObjectID theStream = kObjectID_Stream;
            return ReturnArray(&theStream, sizeof(AudioObjectID), StreamCountForScope(inAddress->mScope),
                               inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyDeviceUID:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kDeviceUID));

        case kAudioDevicePropertyModelUID:
            RETURN_SCALAR(CFStringRef, (CFStringRef)CFRetain(kModelUID));

        case kAudioDevicePropertyTransportType:
            RETURN_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);

        case kAudioDevicePropertyRelatedDevices:
        {
            AudioObjectID theDevice = kObjectID_Device;
            return ReturnArray(&theDevice, sizeof(AudioObjectID), 1, inDataSize, outDataSize, outData);
        }

        //  Zero means this device shares its clock with nothing else.
        case kAudioDevicePropertyClockDomain:
            RETURN_SCALAR(UInt32, 0);

        case kAudioDevicePropertyDeviceIsAlive:
            RETURN_SCALAR(UInt32, 1);

        case kAudioDevicePropertyDeviceIsRunning:
            RETURN_SCALAR(UInt32, (gIOClientCount > 0) ? 1 : 0);

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            RETURN_SCALAR(UInt32, 1);

        case kAudioDevicePropertyIsHidden:
            RETURN_SCALAR(UInt32, 0);

        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
            RETURN_SCALAR(UInt32, 0);

        case kAudioObjectPropertyControlList:
            return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);

        case kAudioDevicePropertyZeroTimeStampPeriod:
            RETURN_SCALAR(UInt32, kRingBufferFrames);

        case kAudioDevicePropertyNominalSampleRate:
            RETURN_SCALAR(Float64, kSampleRate);

        case kAudioDevicePropertyAvailableNominalSampleRates:
        {
            AudioValueRange theRange = { kSampleRate, kSampleRate };
            return ReturnArray(&theRange, sizeof(AudioValueRange), 1, inDataSize, outDataSize, outData);
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
            UInt32 thePair[] = { 1, 2 };
            return ReturnArray(thePair, sizeof(UInt32), 2, inDataSize, outDataSize, outData);
        }

        case kAudioDevicePropertyPreferredChannelLayout:
        {
            UInt32 theSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription));
            if(outData != NULL)
            {
                if(inDataSize < theSize) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout* theLayout = (AudioChannelLayout*)outData;
                memset(theLayout, 0, theSize);
                theLayout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                theLayout->mNumberChannelDescriptions = kChannelCount;
                theLayout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                theLayout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
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
                if(theStreams > 0)
                {
                    theList->mBuffers[0].mNumberChannels = kChannelCount;
                    theList->mBuffers[0].mDataByteSize = 0;
                    theList->mBuffers[0].mData = NULL;
                }
            }
            *outDataSize = theSize;
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Stream object properties

static OSStatus Stream_GetProperty(const AudioObjectPropertyAddress* inAddress,
                                   UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyBaseClass:
            RETURN_SCALAR(AudioClassID, kAudioObjectClassID);

        case kAudioObjectPropertyClass:
            RETURN_SCALAR(AudioClassID, kAudioStreamClassID);

        case kAudioObjectPropertyOwner:
            RETURN_SCALAR(AudioObjectID, kObjectID_Device);

        case kAudioObjectPropertyOwnedObjects:
            return ReturnArray(NULL, sizeof(AudioObjectID), 0, inDataSize, outDataSize, outData);

        case kAudioStreamPropertyIsActive:
            RETURN_SCALAR(UInt32, gStreamIsActive);

        //  Zero marks an output stream.
        case kAudioStreamPropertyDirection:
            RETURN_SCALAR(UInt32, 0);

        case kAudioStreamPropertyTerminalType:
            RETURN_SCALAR(UInt32, kAudioStreamTerminalTypeSpeaker);

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
                FillFormat((AudioStreamBasicDescription*)outData);
            }
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return 0;
        }

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        {
            AudioStreamRangedDescription theRanged;
            memset(&theRanged, 0, sizeof(theRanged));
            FillFormat(&theRanged.mFormat);
            theRanged.mSampleRateRange.mMinimum = kSampleRate;
            theRanged.mSampleRateRange.mMaximum = kSampleRate;
            return ReturnArray(&theRanged, sizeof(AudioStreamRangedDescription), 1, inDataSize, outDataSize, outData);
        }

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
    switch(inObjectID)
    {
        case kAudioObjectPlugInObject:
            theError = PlugIn_GetProperty(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
            break;

        case kObjectID_Box:
            theError = Box_GetProperty(inAddress, inDataSize, outDataSize, outData);
            break;

        case kObjectID_Device:
            theError = Device_GetProperty(inAddress, inDataSize, outDataSize, outData);
            break;

        case kObjectID_Stream:
            theError = Stream_GetProperty(inAddress, inDataSize, outDataSize, outData);
            break;

        default:
            theError = kAudioHardwareBadObjectError;
            break;
    }
    pthread_mutex_unlock(&gStateMutex);

    return theError;
}

#pragma mark - Driver interface: administration

static OSStatus Mixanimo_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    (void)inDriver;
    mach_timebase_info_data_t theTimeBase;
    mach_timebase_info(&theTimeBase);
    Float64 theTicksPerSecond = 1.0e9 * ((Float64)theTimeBase.denom / (Float64)theTimeBase.numer);

    pthread_mutex_lock(&gStateMutex);
    gHost = inHost;
    gHostTicksPerRingBuffer = (theTicksPerSecond / kSampleRate) * (Float64)kRingBufferFrames;
    pthread_mutex_unlock(&gStateMutex);

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

static OSStatus Mixanimo_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                         const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inClientInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus Mixanimo_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                            const AudioServerPlugInClientInfo* inClientInfo)
{
    (void)inDriver; (void)inClientInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus Mixanimo_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                          UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inChangeAction; (void)inChangeInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus Mixanimo_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                        UInt64 inChangeAction, void* inChangeInfo)
{
    (void)inDriver; (void)inChangeAction; (void)inChangeInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
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
    if(outIsSettable == NULL) return kAudioHardwareIllegalOperationError;

    UInt32 theSize = 0;
    OSStatus theError = GetProperty(inObjectID, inAddress, 0, NULL, 0, &theSize, NULL);
    if(theError != 0) return theError;

    switch(inAddress->mSelector)
    {
        case kAudioObjectPropertyIdentify:
            *outIsSettable = (inObjectID == kObjectID_Box);
            break;

        case kAudioBoxPropertyAcquired:
            *outIsSettable = (inObjectID == kObjectID_Box);
            break;

        case kAudioDevicePropertyNominalSampleRate:
            *outIsSettable = (inObjectID == kObjectID_Device);
            break;

        case kAudioStreamPropertyIsActive:
            *outIsSettable = (inObjectID == kObjectID_Stream);
            break;

        default:
            *outIsSettable = false;
            break;
    }

    (void)inDriver; (void)inClientProcessID;
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

static OSStatus Mixanimo_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                         pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                         UInt32 inQualifierDataSize, const void* inQualifierData,
                                         UInt32 inDataSize, const void* inData)
{
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;

    if((inAddress == NULL) || (inData == NULL)) return kAudioHardwareIllegalOperationError;

    //  Collected inside the lock and sent to the host outside it.
    AudioObjectPropertyAddress theChanged[2];
    UInt32 theChangedCount = 0;
    OSStatus theError = 0;

    pthread_mutex_lock(&gStateMutex);
    switch(inObjectID)
    {
        case kObjectID_Box:
            if(inAddress->mSelector == kAudioObjectPropertyIdentify)
            {
                //  Nothing to flash on a virtual box.
            }
            else if(inAddress->mSelector == kAudioBoxPropertyAcquired)
            {
                if(inDataSize != sizeof(UInt32)) { theError = kAudioHardwareBadPropertySizeError; break; }
                UInt32 theNew = (*((const UInt32*)inData) != 0) ? 1 : 0;
                if(theNew != gBoxAcquired)
                {
                    gBoxAcquired = theNew;
                    theChanged[0] = (AudioObjectPropertyAddress){ kAudioBoxPropertyAcquired, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                    theChanged[1] = (AudioObjectPropertyAddress){ kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                    theChangedCount = 2;
                }
            }
            else
            {
                theError = kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Device:
            if(inAddress->mSelector == kAudioDevicePropertyNominalSampleRate)
            {
                if(inDataSize != sizeof(Float64)) { theError = kAudioHardwareBadPropertySizeError; break; }
                if(*((const Float64*)inData) != kSampleRate) theError = kAudioHardwareIllegalOperationError;
            }
            else
            {
                theError = kAudioHardwareUnknownPropertyError;
            }
            break;

        case kObjectID_Stream:
            if(inAddress->mSelector == kAudioStreamPropertyIsActive)
            {
                if(inDataSize != sizeof(UInt32)) { theError = kAudioHardwareBadPropertySizeError; break; }
                gStreamIsActive = (*((const UInt32*)inData) != 0) ? 1 : 0;
            }
            else
            {
                theError = kAudioHardwareUnknownPropertyError;
            }
            break;

        default:
            theError = kAudioHardwareBadObjectError;
            break;
    }
    AudioServerPlugInHostRef theHost = gHost;
    pthread_mutex_unlock(&gStateMutex);

    if((theChangedCount > 0) && (theHost != NULL))
    {
        theHost->PropertiesChanged(theHost, inObjectID, theChangedCount, theChanged);
        AudioObjectPropertyAddress theDeviceList = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        theHost->PropertiesChanged(theHost, kAudioObjectPlugInObject, 1, &theDeviceList);
    }

    return theError;
}

#pragma mark - Driver interface: IO

static OSStatus Mixanimo_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if(gIOClientCount == 0)
    {
        gAnchorHostTime = mach_absolute_time();
        gTimeStampCount = 0;
    }
    ++gIOClientCount;
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

static OSStatus Mixanimo_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inDriver; (void)inClientID;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    if(gIOClientCount > 0) --gIOClientCount;
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

//  The device has no hardware clock, so the host clock paces it one ring buffer at a time.
static OSStatus Mixanimo_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inDriver; (void)inClientID;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    pthread_mutex_lock(&gStateMutex);
    UInt64 theNextHostTime = gAnchorHostTime + (UInt64)(((Float64)(gTimeStampCount + 1)) * gHostTicksPerRingBuffer);
    if(mach_absolute_time() >= theNextHostTime)
    {
        ++gTimeStampCount;
    }
    *outSampleTime = (Float64)(gTimeStampCount * kRingBufferFrames);
    *outHostTime = gAnchorHostTime + (UInt64)(((Float64)gTimeStampCount) * gHostTicksPerRingBuffer);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);

    return 0;
}

static OSStatus Mixanimo_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                           UInt32 inClientID, UInt32 inOperationID,
                                           Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inDriver; (void)inClientID;
    if(inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;

    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;
    return 0;
}

static OSStatus Mixanimo_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

//  The mix is discarded until the ring buffer that feeds the app exists.
static OSStatus Mixanimo_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                       UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                       void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver; (void)inStreamObjectID; (void)inClientID; (void)inOperationID;
    (void)inIOBufferFrameSize; (void)inIOCycleInfo; (void)ioMainBuffer; (void)ioSecondaryBuffer;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus Mixanimo_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    (void)inDriver; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return (inDeviceObjectID == kObjectID_Device) ? 0 : kAudioHardwareBadObjectError;
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
