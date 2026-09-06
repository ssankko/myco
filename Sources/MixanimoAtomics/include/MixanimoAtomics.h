#ifndef MIXANIMO_ATOMICS_H
#define MIXANIMO_ATOMICS_H

#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/mman.h>

// C11 atomics over plain 64-bit slots. Swift's Synchronization.Atomic needs macOS 15 and the
// deployment target is macOS 14, so lock-free code in the DSP layer names its memory ordering here.
// Every slot passed in must be naturally aligned, which UnsafeMutablePointer<UInt64> guarantees.

static inline uint64_t mixanimo_atomic_load_acquire(const uint64_t *slot) {
    return atomic_load_explicit((const _Atomic uint64_t *)slot, memory_order_acquire);
}

static inline void mixanimo_atomic_store_release(uint64_t *slot, uint64_t value) {
    atomic_store_explicit((_Atomic uint64_t *)slot, value, memory_order_release);
}

static inline uint64_t mixanimo_atomic_load_relaxed(const uint64_t *slot) {
    return atomic_load_explicit((const _Atomic uint64_t *)slot, memory_order_relaxed);
}

static inline void mixanimo_atomic_store_relaxed(uint64_t *slot, uint64_t value) {
    atomic_store_explicit((_Atomic uint64_t *)slot, value, memory_order_relaxed);
}

// shm_open is variadic in the C header, which Swift cannot call, so the one call the app makes
// lives here. The driver owns the object; the app only ever reads it.
static inline int mixanimo_shm_open_read_only(const char *name) {
    return shm_open(name, O_RDONLY);
}

#endif
