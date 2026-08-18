// Sources/AiVoiceKit/macOS/AudioStartupGate.swift
// Ported from FluidVoice/Sources/Fluid/Services/AudioStartupGate.swift
// Changes: wrapped in #if os(macOS), updated label namespace.
#if os(macOS)
import Foundation

/// Centralized startup gate for any code path that can trigger CoreAudio initialization.
///
/// SwiftUI / AttributeGraph does not expose a reliable "initial metadata processing complete"
/// signal. CoreAudio / AVFoundation initialization that races that work during app launch
/// causes EXC_BAD_ACCESS. A single shared gate makes it much harder for new call-sites
/// (e.g., Settings views) to accidentally trigger CoreAudio too early.
actor AudioStartupGate {
    static let shared = AudioStartupGate()

    private var isOpen: Bool = false
    private var openTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Schedule opening the gate once. Safe to call multiple times.
    func scheduleOpenAfterInitialUISettled(delayNanoseconds: UInt64 = 2_000_000_000) {
        guard !isOpen, openTask == nil else { return }

        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Give SwiftUI a couple of run-loop turns to finish initial layout/metadata.
            await Task.yield()
            await Task.yield()
            // Safety delay for slower or heavily loaded systems.
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await self.open()
        }
    }

    /// Suspend until the gate is open. Returns immediately if already open.
    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    private func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}
#endif
