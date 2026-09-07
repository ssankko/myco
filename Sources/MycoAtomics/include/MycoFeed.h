#ifndef MYCO_FEED_H
#define MYCO_FEED_H

#include <stddef.h>
#include <stdint.h>

#include "MycoAtomics.h"

//  The layout of the `Myco` shared ring, which the driver writes and the app maps read only.
//  Both sides read this header, so the bytes are described once.

#define kFeedName               "/myco-feed"
#define kFeedMagic              0x4D584644u     /* 'MXFD' */
#define kFeedLayoutVersion      1u
#define kFeedChannels           2u
//  Power of two so a frame position maps to a ring index with a mask, and 131072 frames are 1.4
//  seconds at 96 kHz.
#define kFeedRingFrames         (1u << 17)
//  The header owns a whole page, so the float data starts page aligned.
#define kFeedHeaderBytes        4096u

//  What the app finds at the start of the shared object. The two groups sit on their own 64-byte
//  line: the first is written when the driver loads or the rate changes, the second on every IO
//  cycle. mMagic is stored last, so a reader that sees it sees a whole header.
//
//  The two slots the IO path touches are plain integers that the functions below reach through
//  C11 atomics, because a struct carrying _Atomic members cannot be imported into Swift.
typedef struct
{
    uint32_t    mMagic;
    uint32_t    mLayoutVersion;
    uint32_t    mChannels;
    uint32_t    mRingFrames;
    double      mSampleRate;
    //  A fresh value per Initialize, which is how a reader notices that coreaudiod restarted.
    uint64_t    mGeneration;
    uint8_t     mDescriptionPad[64 - 32];

    //  Frames written since the device last started. The release store publishes the samples.
    uint64_t    mWriteFrame;
    //  Frames the last IO cycle carried, which tells a reader how far behind to sit.
    uint32_t    mWriteBlockFrames;
    uint8_t     mWritePad[64 - 12];
} MycoFeedHeader;

_Static_assert(sizeof(MycoFeedHeader) <= kFeedHeaderBytes, "the feed header must fit its page");
_Static_assert(offsetof(MycoFeedHeader, mWriteFrame) == 64, "the IO slots own their cache line");

//  The whole handshake between the two processes: whoever acquires this position sees every sample
//  written below it.
static inline uint64_t myco_feed_write_frame(const MycoFeedHeader *header) {
    return myco_atomic_load_acquire(&header->mWriteFrame);
}

//  Driver, from its IO thread: the block first, then the position that publishes the samples.
static inline void myco_feed_publish(
    MycoFeedHeader *header, uint32_t blockFrames, uint64_t writeFrame) {
    atomic_store_explicit(
        (_Atomic uint32_t *)&header->mWriteBlockFrames, blockFrames, memory_order_relaxed);
    myco_atomic_store_release(&header->mWriteFrame, writeFrame);
}

//  Driver, with IO stopped: the ring starts over from zero.
static inline void myco_feed_rewind(MycoFeedHeader *header) {
    myco_atomic_store_release(&header->mWriteFrame, 0);
}

//  Driver, once the rest of the header is written: the magic tells a reader the header is whole.
static inline void myco_feed_ready(MycoFeedHeader *header) {
    atomic_store_explicit((_Atomic uint32_t *)&header->mMagic, kFeedMagic, memory_order_release);
}

#endif
