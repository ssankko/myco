#ifndef MixanimoDriver_h
#define MixanimoDriver_h

#include <CoreFoundation/CoreFoundation.h>

//  CFPlugIn entry point named by CFPlugInFactories in the driver bundle's Info.plist.
void* MixanimoDriverFactory(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

#endif
