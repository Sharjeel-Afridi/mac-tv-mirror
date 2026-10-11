import Foundation

/// Minimal thread-safe box; safe to touch from async contexts (uses scoped locking).
final class Locked<T> {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func get() -> T {
        lock.withLock { value }
    }

    func set(_ newValue: T) {
        lock.withLock { value = newValue }
    }
}
