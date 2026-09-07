#include "MycoAtomics.h"

// The header is all static inline; this file exists so the target has a translation unit.
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "64-bit atomics must be lock free");
