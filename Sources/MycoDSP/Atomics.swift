import MycoAtomics

/// One float handed from the control thread to an IO thread without a lock. All state lives in one
/// allocation, so a copy of the struct is another handle; call `deallocate()` when neither runs.
package struct AtomicFloat: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<UInt64>

    package init(_ value: Float = 0) {
        slot = .allocate(capacity: 1)
        slot.initialize(to: UInt64(value.bitPattern))
    }

    package func deallocate() { slot.deallocate() }

    package var value: Float {
        get { Float(bitPattern: UInt32(truncatingIfNeeded: myco_atomic_load_acquire(slot))) }
        nonmutating set { myco_atomic_store_release(slot, UInt64(newValue.bitPattern)) }
    }
}

/// A count raised on one IO thread and read from anywhere, which is how the engine reports events
/// that happen in a callback without touching the main actor from it.
package struct AtomicCounter: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<UInt64>

    package init() {
        slot = .allocate(capacity: 1)
        slot.initialize(to: 0)
    }

    package func deallocate() { slot.deallocate() }

    package var value: Int { Int(myco_atomic_load_acquire(slot)) }

    /// IO thread only: the single writer needs no read-modify-write.
    package func add(_ count: Int) {
        myco_atomic_store_release(slot, myco_atomic_load_relaxed(slot) &+ UInt64(count))
    }

    /// Control thread only, for a count that is handed over rather than accumulated.
    package func set(_ value: Int) {
        myco_atomic_store_release(slot, UInt64(max(0, value)))
    }
}
