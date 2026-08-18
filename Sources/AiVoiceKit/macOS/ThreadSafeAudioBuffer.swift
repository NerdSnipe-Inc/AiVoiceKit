// Sources/AiVoiceKit/macOS/ThreadSafeAudioBuffer.swift
// Ported from FluidVoice/Sources/Fluid/Services/ThreadSafeAudioBuffer.swift
// Changes: wrapped in #if os(macOS)
#if os(macOS)
import Foundation

/// Thread-safe wrapper around a float array for safe handoff between the
/// audio capture thread and ASR consumers running on other threads.
final class ThreadSafeAudioBuffer: @unchecked Sendable {
    private var buffer: [Float] = []
    private let lock = NSLock()

    /// Appends samples to the buffer in a thread-safe manner.
    func append(_ newSamples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: newSamples)
    }

    /// Clears the buffer, optionally keeping capacity to reduce allocations.
    func clear(keepingCapacity: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: keepingCapacity)
    }

    /// Returns the current sample count (thread-safe).
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// Returns a copy of the leading `length` samples (thread-safe).
    func getPrefix(_ length: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let safeLength = min(length, buffer.count)
        return Array(buffer[0..<safeLength])
    }

    /// Returns a copy of the entire buffer (thread-safe).
    func getAll() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
#endif
