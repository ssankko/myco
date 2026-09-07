#ifndef MycoDriver_h
#define MycoDriver_h

#include <CoreFoundation/CoreFoundation.h>

//  CFPlugIn entry point named by CFPlugInFactories in the driver bundle's Info.plist.
void* MycoDriverFactory(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

#endif
