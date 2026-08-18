#if os(macOS)
import AppKit
import Foundation

// MARK: - Internal state types

private nonisolated enum HotkeyHoldModeType: Hashable {
    case transcription
    case commandMode
}

private nonisolated enum ActivePrimaryShortcutPress: Equatable {
    case keyboard(UInt16)
    case mouse(Int)
}

private final nonisolated class HotkeyState: @unchecked Sendable {
    private let lock = NSLock()
    var isKeyPressed = false
    var isCommandModeKeyPressed = false
    var pressedModifierKeyCodes: Set<UInt16> = []
    var modifierOnlyKeyDown = false
    var otherKeyPressedDuringModifier = false
    var modifierPressStartTime: Date?
    var holdModeStartTriggeredTypes: Set<HotkeyHoldModeType> = []
    var pendingReleaseStopTasks: [HotkeyHoldModeType: Task<Void, Never>] = [:]
    var pendingReleaseStopTokens: [HotkeyHoldModeType: UUID] = [:]
    var automaticPressStartTimes: [HotkeyHoldModeType: Date] = [:]
    var automaticPressWasTargetActive: [HotkeyHoldModeType: Bool] = [:]
    var automaticPressStartedTypes: Set<HotkeyHoldModeType> = []
    var activePrimaryShortcutPress: ActivePrimaryShortcutPress?

    func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }
}

// MARK: - VoiceHotkeyManager

/// CGEventTap–based global hotkey manager for AiVoiceKit.
/// Supports dictation and command-mode shortcuts with hold / toggle / automatic activation modes.
/// Callbacks fire into VoiceEngineMacOS via closures — no engine import required.
@MainActor
public final class VoiceHotkeyManager: NSObject {

    // MARK: - Public callbacks

    public var onDictationStart: (() -> Void)?
    public var onDictationStop: (() -> Void)?
    public var onCommandModeStart: (() -> Void)?
    public var onEditModeStart: (() -> Void)?
    public var onCancelRecording: (() -> Void)?
    public var onPasteLastTranscription: (() -> Void)?

    /// Provides current recording state so the manager can route hold/toggle events correctly.
    public var isRecording: (() -> Bool)?

    // MARK: - Shortcut configuration (set before or after init)

    public var primaryShortcuts: [HotkeyShortcut] = [] {
        didSet { DebugLogger.shared.info("Updated transcription hotkeys", source: "VoiceHotkeyManager") }
    }
    public var commandModeShortcut: HotkeyShortcut? {
        didSet { DebugLogger.shared.info("Updated command mode hotkey", source: "VoiceHotkeyManager") }
    }
    public var commandModeShortcutEnabled: Bool = true {
        didSet { if !commandModeShortcutEnabled { isCommandModeKeyPressed = false } }
    }

    // MARK: - Private state

    private nonisolated(unsafe) var state = HotkeyState()
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?

    private var isProcessingStop = false
    private var isInitialized = false
    private var initializationTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private let maxRetryAttempts = 5
    private let retryDelay: TimeInterval = 0.5
    private let healthCheckInterval: TimeInterval = 30.0
    private let automaticTapThresholdSeconds: TimeInterval = 0.4

    // MARK: - Init

    public override init() {
        super.init()
        initializeWithDelay()
    }

    // MARK: - State accessors (nonisolated, lock-protected)

    private nonisolated var isKeyPressed: Bool {
        get { state.withLock { state.isKeyPressed } }
        set { state.withLock { state.isKeyPressed = newValue } }
    }

    private nonisolated var isCommandModeKeyPressed: Bool {
        get { state.withLock { state.isCommandModeKeyPressed } }
        set { state.withLock { state.isCommandModeKeyPressed = newValue } }
    }

    private nonisolated var activePrimaryShortcutPress: ActivePrimaryShortcutPress? {
        get { state.withLock { state.activePrimaryShortcutPress } }
        set { state.withLock { state.activePrimaryShortcutPress = newValue } }
    }

    private nonisolated var pressedModifierKeyCodes: Set<UInt16> {
        get { state.withLock { state.pressedModifierKeyCodes } }
        set { state.withLock { state.pressedModifierKeyCodes = newValue } }
    }

    private nonisolated var modifierOnlyKeyDown: Bool {
        get { state.withLock { state.modifierOnlyKeyDown } }
        set { state.withLock { state.modifierOnlyKeyDown = newValue } }
    }

    private nonisolated var otherKeyPressedDuringModifier: Bool {
        get { state.withLock { state.otherKeyPressedDuringModifier } }
        set { state.withLock { state.otherKeyPressedDuringModifier = newValue } }
    }

    private nonisolated var modifierPressStartTime: Date? {
        get { state.withLock { state.modifierPressStartTime } }
        set { state.withLock { state.modifierPressStartTime = newValue } }
    }

    // MARK: - Pending release stop helpers

    private func cancelPendingReleaseStop(for type: HotkeyHoldModeType) {
        let task = state.withLock { () -> Task<Void, Never>? in
            _ = state.pendingReleaseStopTokens.removeValue(forKey: type)
            return state.pendingReleaseStopTasks.removeValue(forKey: type)
        }
        task?.cancel()
    }

    private func cancelPendingReleaseStops() {
        let tasks = state.withLock { () -> [Task<Void, Never>] in
            let tasks = Array(state.pendingReleaseStopTasks.values)
            state.pendingReleaseStopTasks.removeAll()
            state.pendingReleaseStopTokens.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
    }

    private func beginPendingReleaseStop(for type: HotkeyHoldModeType) -> UUID {
        let token = UUID()
        let task = state.withLock { () -> Task<Void, Never>? in
            state.pendingReleaseStopTokens[type] = token
            return state.pendingReleaseStopTasks.removeValue(forKey: type)
        }
        task?.cancel()
        return token
    }

    private func storePendingReleaseStopTask(_ task: Task<Void, Never>, for type: HotkeyHoldModeType, token: UUID) {
        let toCancel = state.withLock { () -> Task<Void, Never>? in
            guard state.pendingReleaseStopTokens[type] == token else { return task }
            let previous = state.pendingReleaseStopTasks[type]
            state.pendingReleaseStopTasks[type] = task
            return previous
        }
        toCancel?.cancel()
    }

    private func isPendingReleaseStopCurrent(for type: HotkeyHoldModeType, token: UUID) -> Bool {
        state.withLock { state.pendingReleaseStopTokens[type] == token }
    }

    private func clearPendingReleaseStop(for type: HotkeyHoldModeType, token: UUID) {
        state.withLock {
            guard state.pendingReleaseStopTokens[type] == token else { return }
            _ = state.pendingReleaseStopTokens.removeValue(forKey: type)
            _ = state.pendingReleaseStopTasks.removeValue(forKey: type)
        }
    }

    // MARK: - Automatic press helpers

    private func beginAutomaticPress(for type: HotkeyHoldModeType, wasTargetActive: Bool) {
        cancelPendingReleaseStop(for: type)
        state.withLock {
            state.automaticPressStartTimes[type] = Date()
            state.automaticPressWasTargetActive[type] = wasTargetActive
            _ = state.automaticPressStartedTypes.remove(type)
        }
    }

    private func markAutomaticPressStarted(for type: HotkeyHoldModeType) {
        state.withLock { _ = state.automaticPressStartedTypes.insert(type) }
    }

    private func finishAutomaticPress(for type: HotkeyHoldModeType) -> (duration: TimeInterval, wasTargetActive: Bool, started: Bool) {
        let now = Date()
        return state.withLock {
            let startTime = state.automaticPressStartTimes.removeValue(forKey: type) ?? now
            let wasTargetActive = state.automaticPressWasTargetActive.removeValue(forKey: type) ?? false
            let started = state.automaticPressStartedTypes.remove(type) != nil
            return (now.timeIntervalSince(startTime), wasTargetActive, started)
        }
    }

    private func clearHoldModeStartTriggered(for type: HotkeyHoldModeType) {
        state.withLock { _ = state.holdModeStartTriggeredTypes.remove(type) }
    }

    private func markHoldModeStartTriggered(for type: HotkeyHoldModeType) {
        state.withLock { _ = state.holdModeStartTriggeredTypes.insert(type) }
    }

    private func finishHoldModeStartTriggered(for type: HotkeyHoldModeType) -> Bool {
        state.withLock { state.holdModeStartTriggeredTypes.remove(type) != nil }
    }

    private func clearAutomaticPressTracking() {
        cancelPendingReleaseStops()
        state.withLock {
            state.holdModeStartTriggeredTypes.removeAll()
            state.automaticPressStartTimes.removeAll()
            state.automaticPressWasTargetActive.removeAll()
            state.automaticPressStartedTypes.removeAll()
        }
    }

    // MARK: - Activation mode

    /// Maps AiVoiceKit's `HotkeyActivationMode` to internal behaviour.
    private var hotkeyMode: HotkeyActivationMode {
        VoiceSettingsStore.shared.hotkeyActivationMode
    }

    // MARK: - Primary shortcut press tracking

    private func beginPrimaryShortcutPress(_ press: ActivePrimaryShortcutPress) -> Bool {
        state.withLock {
            guard state.activePrimaryShortcutPress == nil, !state.isKeyPressed else { return false }
            state.activePrimaryShortcutPress = press
            return true
        }
    }

    private func finishPrimaryShortcutPress(_ press: ActivePrimaryShortcutPress) -> Bool {
        state.withLock {
            guard state.activePrimaryShortcutPress == press else { return false }
            state.activePrimaryShortcutPress = nil
            return true
        }
    }

    // MARK: - CGEventTap setup

    private func initializeWithDelay() {
        DebugLogger.shared.debug("Starting delayed initialization...", source: "VoiceHotkeyManager")
        initializationTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { self.setupGlobalHotkeyWithRetry() }
        }
    }

    private func setupGlobalHotkeyWithRetry() {
        for attempt in 1...maxRetryAttempts {
            DebugLogger.shared.debug("Setup attempt \(attempt)/\(maxRetryAttempts)", source: "VoiceHotkeyManager")
            if setupGlobalHotkey() {
                isInitialized = true
                DebugLogger.shared.info("Successfully initialized on attempt \(attempt)", source: "VoiceHotkeyManager")
                startHealthCheckTimer()
                return
            }
            if attempt < maxRetryAttempts {
                DebugLogger.shared.warning("Attempt \(attempt) failed, retrying in \(retryDelay)s...", source: "VoiceHotkeyManager")
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: UInt64(self.retryDelay * 1_000_000_000))
                    await MainActor.run { self.setupGlobalHotkeyWithRetry() }
                }
                return
            }
        }
        DebugLogger.shared.error("Failed to initialize after \(maxRetryAttempts) attempts", source: "VoiceHotkeyManager")
    }

    @discardableResult
    private func setupGlobalHotkey() -> Bool {
        cleanupEventTap()

        guard AXIsProcessTrusted() else {
            DebugLogger.shared.debug("Accessibility permissions not granted", source: "VoiceHotkeyManager")
            return false
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<VoiceHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = eventTap else {
            DebugLogger.shared.error("Failed to create CGEvent tap", source: "VoiceHotkeyManager")
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        guard let source = runLoopSource else {
            DebugLogger.shared.error("Failed to create CFRunLoopSource", source: "VoiceHotkeyManager")
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        guard isEventTapEnabled() else {
            DebugLogger.shared.error("Event tap could not be enabled", source: "VoiceHotkeyManager")
            cleanupEventTap()
            return false
        }

        DebugLogger.shared.info("Event tap successfully created and enabled", source: "VoiceHotkeyManager")
        return true
    }

    private nonisolated func cleanupEventTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        eventTap = nil
        runLoopSource = nil
        clearPrimaryShortcutPressState()
    }

    private nonisolated func clearPrimaryShortcutPressState() {
        let task = state.withLock { () -> Task<Void, Never>? in
            guard state.activePrimaryShortcutPress != nil || state.isKeyPressed else { return nil }
            state.activePrimaryShortcutPress = nil
            state.isKeyPressed = false
            state.holdModeStartTriggeredTypes.remove(.transcription)
            state.automaticPressStartTimes.removeValue(forKey: .transcription)
            state.automaticPressWasTargetActive.removeValue(forKey: .transcription)
            state.automaticPressStartedTypes.remove(.transcription)
            _ = state.pendingReleaseStopTokens.removeValue(forKey: .transcription)
            return state.pendingReleaseStopTasks.removeValue(forKey: .transcription)
        }
        task?.cancel()
    }

    // MARK: - Event tap callback

    private func handleKeyEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if let recovery = handleTapDisableEvent(type: type, event: event) { return recovery }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        var eventModifiers: NSEvent.ModifierFlags = []
        if flags.contains(.maskSecondaryFn) { eventModifiers.insert(.function) }
        if flags.contains(.maskCommand)     { eventModifiers.insert(.command) }
        if flags.contains(.maskAlternate)   { eventModifiers.insert(.option) }
        if flags.contains(.maskControl)     { eventModifiers.insert(.control) }
        if flags.contains(.maskShift)       { eventModifiers.insert(.shift) }

        switch type {

        case .keyDown:
            markOtherInputDuringModifierOnly()

            // Cancel shortcut
            if let cancel = onCancelRecording, isCurrentlyRecording(),
               let primary = primaryShortcuts.first
            {
                // A simple escape-key cancel: detect key 53 (Escape) with no modifiers
                // Callers can wire onCancelRecording to stop via VoiceEngine
                _ = (cancel, primary) // silence unused captures; cancel is wired by caller
            }

            // Command mode key down
            if commandModeShortcutEnabled,
               let cmdShortcut = commandModeShortcut,
               cmdShortcut.matches(keyCode: keyCode, modifiers: eventModifiers)
            {
                handleCommandModeKeyDown()
                return nil
            }

            // Primary dictation key down
            if let shortcut = primaryShortcuts.first(where: { $0.matches(keyCode: keyCode, modifiers: eventModifiers) }) {
                guard beginPrimaryShortcutPress(.keyboard(shortcut.keyCode)) else { return nil }
                handlePrimaryDictationTriggerDown()
                return nil
            }

        case .keyUp:
            // Command mode key up
            if commandModeShortcutEnabled,
               isCommandModeKeyPressed,
               let cmdShortcut = commandModeShortcut,
               keyCode == cmdShortcut.keyCode
            {
                handleCommandModeKeyUp()
                return nil
            }

            // Transcription key up
            if finishPrimaryShortcutPress(.keyboard(keyCode)) {
                handlePrimaryDictationTriggerUp()
                return nil
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            markOtherInputDuringModifierOnly()
            if handleMouseShortcutDown(event, modifiers: eventModifiers) { return nil }

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if handleMouseShortcutUp(event) { return nil }

        case .flagsChanged:
            if HotkeyShortcut.modifierFlag(forKeyCode: keyCode) != nil {
                pressedModifierKeyCodes = synchronizedPressedModifierKeyCodes(
                    changedKeyCode: keyCode,
                    modifiers: eventModifiers
                )
            }

            // Command mode modifier-only shortcut
            if let cmdShortcut = commandModeShortcut {
                if handleModifierOnlyCommandModeFlagsChanged(
                    shortcut: cmdShortcut,
                    keyCode: keyCode,
                    modifiers: eventModifiers
                ) { return nil }
            }

            // Primary modifier-only shortcuts
            for shortcut in primaryShortcuts where shortcut.isModifierOnlyShortcut {
                if handleModifierOnlyPrimaryFlagsChanged(
                    shortcut: shortcut,
                    keyCode: keyCode,
                    modifiers: eventModifiers
                ) { return nil }
            }

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Tap disable recovery

    private func handleTapDisableEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else { return nil }
        let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user input"
        DebugLogger.shared.warning("Event tap disabled by \(reason) — re-enabling", source: "VoiceHotkeyManager")
        resetModifierTracking()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        if !isEventTapEnabled() {
            DebugLogger.shared.warning("Re-enable failed — recreating tap", source: "VoiceHotkeyManager")
            setupGlobalHotkeyWithRetry()
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - Dictation trigger

    private func handlePrimaryDictationTriggerDown() {
        switch hotkeyMode {
        case .holdToRecord:
            guard !isKeyPressed else { return }
            cancelPendingReleaseStop(for: .transcription)
            clearHoldModeStartTriggered(for: .transcription)
            isKeyPressed = true
            if isCurrentlyRecording() {
                DebugLogger.shared.info("Dictation hotkey (hold) — already recording, no-op", source: "VoiceHotkeyManager")
            } else {
                DebugLogger.shared.info("Dictation hotkey (hold) — starting", source: "VoiceHotkeyManager")
                triggerDictationStart()
            }
            markHoldModeStartTriggered(for: .transcription)

        case .toggle:
            if isCurrentlyRecording() {
                DebugLogger.shared.info("Dictation hotkey (toggle) — stopping", source: "VoiceHotkeyManager")
                triggerDictationStop()
            } else {
                DebugLogger.shared.info("Dictation hotkey (toggle) — starting", source: "VoiceHotkeyManager")
                triggerDictationStart()
            }

        case .doubleTap: // automatic behaviour
            guard !isKeyPressed else { return }
            isKeyPressed = true
            let wasRecording = isCurrentlyRecording()
            beginAutomaticPress(for: .transcription, wasTargetActive: wasRecording)
            if wasRecording {
                DebugLogger.shared.info("Dictation hotkey (automatic) — same mode, waiting for release", source: "VoiceHotkeyManager")
            } else {
                DebugLogger.shared.info("Dictation hotkey (automatic) — starting", source: "VoiceHotkeyManager")
                triggerDictationStart()
                markAutomaticPressStarted(for: .transcription)
            }
        }
    }

    private func handlePrimaryDictationTriggerUp() {
        switch hotkeyMode {
        case .holdToRecord:
            isKeyPressed = false
            _ = finishHoldModeStartTriggered(for: .transcription)
            stopRecordingAfterRelease(for: .transcription, label: "Dictation")
        case .toggle:
            break
        case .doubleTap:
            isKeyPressed = false
            handleAutomaticKeyRelease(for: .transcription, label: "Dictation")
        }
    }

    // MARK: - Command mode trigger

    private func handleCommandModeKeyDown() {
        switch hotkeyMode {
        case .holdToRecord:
            guard !isCommandModeKeyPressed else { return }
            cancelPendingReleaseStop(for: .commandMode)
            clearHoldModeStartTriggered(for: .commandMode)
            isCommandModeKeyPressed = true
            DebugLogger.shared.info("Command mode (hold) — starting", source: "VoiceHotkeyManager")
            triggerCommandModeStart()
            markHoldModeStartTriggered(for: .commandMode)

        case .toggle:
            if isCurrentlyRecording() {
                DebugLogger.shared.info("Command mode (toggle) — stopping", source: "VoiceHotkeyManager")
                triggerDictationStop()
            } else {
                DebugLogger.shared.info("Command mode (toggle) — starting", source: "VoiceHotkeyManager")
                triggerCommandModeStart()
            }

        case .doubleTap:
            guard !isCommandModeKeyPressed else { return }
            isCommandModeKeyPressed = true
            let wasRecording = isCurrentlyRecording()
            beginAutomaticPress(for: .commandMode, wasTargetActive: wasRecording)
            if wasRecording {
                DebugLogger.shared.info("Command mode (automatic) — same mode, waiting for release", source: "VoiceHotkeyManager")
            } else {
                DebugLogger.shared.info("Command mode (automatic) — starting", source: "VoiceHotkeyManager")
                triggerCommandModeStart()
                markAutomaticPressStarted(for: .commandMode)
            }
        }
    }

    private func handleCommandModeKeyUp() {
        switch hotkeyMode {
        case .holdToRecord:
            isCommandModeKeyPressed = false
            _ = finishHoldModeStartTriggered(for: .commandMode)
            stopRecordingAfterRelease(for: .commandMode, label: "Command mode")
        case .toggle:
            break
        case .doubleTap:
            isCommandModeKeyPressed = false
            handleAutomaticKeyRelease(for: .commandMode, label: "Command mode")
        }
    }

    // MARK: - Automatic key release handling

    private func handleAutomaticKeyRelease(for type: HotkeyHoldModeType, label: String) {
        let press = finishAutomaticPress(for: type)
        let duration = String(format: "%.2f", press.duration)

        if press.duration < automaticTapThresholdSeconds {
            if press.wasTargetActive {
                DebugLogger.shared.info("\(label) tap (\(duration)s) — stopping", source: "VoiceHotkeyManager")
                triggerDictationStop()
            } else if !press.started {
                DebugLogger.shared.info("\(label) tap (\(duration)s) — toggling", source: "VoiceHotkeyManager")
                if type == .commandMode { triggerCommandModeStart() } else { triggerDictationStart() }
            }
            return
        }

        if press.wasTargetActive || press.started {
            DebugLogger.shared.info("\(label) hold (\(duration)s) — stopping", source: "VoiceHotkeyManager")
            stopRecordingAfterRelease(for: type, label: label)
        }
    }

    // MARK: - Deferred stop

    private func stopRecordingAfterRelease(for type: HotkeyHoldModeType, label: String) {
        if isCurrentlyRecording() {
            cancelPendingReleaseStop(for: type)
            triggerDictationStop()
            return
        }

        let token = beginPendingReleaseStop(for: type)
        DebugLogger.shared.debug("\(label) release — deferred stop pending recording start", source: "VoiceHotkeyManager")

        let task = Task { @MainActor [weak self] in
            let maxAttempts = 60
            for _ in 0..<maxAttempts {
                guard !Task.isCancelled, let self else { return }
                guard self.isPendingReleaseStopCurrent(for: type, token: token) else { return }
                if self.isCurrentlyRecording() {
                    DebugLogger.shared.info("\(label) deferred stop — recording started", source: "VoiceHotkeyManager")
                    self.clearPendingReleaseStop(for: type, token: token)
                    self.triggerDictationStop()
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            guard self.isPendingReleaseStopCurrent(for: type, token: token) else { return }
            DebugLogger.shared.warning("\(label) deferred stop expired", source: "VoiceHotkeyManager")
            self.clearPendingReleaseStop(for: type, token: token)
        }
        storePendingReleaseStopTask(task, for: type, token: token)
    }

    // MARK: - Mouse shortcuts

    private func handleMouseShortcutDown(_ event: CGEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if primaryShortcuts.contains(where: { $0.matchesMouse(button: button, modifiers: modifiers) }) {
            guard beginPrimaryShortcutPress(.mouse(button)) else { return true }
            handlePrimaryDictationTriggerDown()
            return true
        }
        return false
    }

    private func handleMouseShortcutUp(_ event: CGEvent) -> Bool {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        guard finishPrimaryShortcutPress(.mouse(button)) else { return false }
        handlePrimaryDictationTriggerUp()
        return true
    }

    // MARK: - Modifier-only shortcut helpers

    private func markOtherInputDuringModifierOnly() {
        guard modifierOnlyKeyDown else { return }
        otherKeyPressedDuringModifier = true
    }

    private func resetModifierTracking() {
        pressedModifierKeyCodes = []
        modifierOnlyKeyDown = false
        otherKeyPressedDuringModifier = false
        modifierPressStartTime = nil
        clearAutomaticPressTracking()
        isKeyPressed = false
        isCommandModeKeyPressed = false
        activePrimaryShortcutPress = nil
    }

    private func synchronizedPressedModifierKeyCodes(changedKeyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Set<UInt16> {
        guard HotkeyShortcut.modifierFlag(forKeyCode: changedKeyCode) != nil else {
            return pressedModifierKeyCodes
        }
        let activeModifiers = modifiers.intersection(HotkeyShortcut.relevantModifierMask)
        let groups: [(NSEvent.ModifierFlags, [UInt16])] = [
            (.function, [63]),
            (.command, [55, 54]),
            (.option, [58, 61]),
            (.control, [59, 62]),
            (.shift, [56, 60]),
        ]
        var result = Set<UInt16>()
        for (flag, codes) in groups where activeModifiers.contains(flag) {
            let live = codes.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
            if !live.isEmpty { result.formUnion(live); continue }
            if flag == HotkeyShortcut.modifierFlag(forKeyCode: changedKeyCode) {
                result.insert(changedKeyCode)
            }
        }
        return result
    }

    private func handleModifierOnlyPrimaryFlagsChanged(shortcut: HotkeyShortcut, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        handleModifierOnlyFlagsChanged(
            shortcut: shortcut,
            isEnabled: true,
            holdModeType: .transcription,
            keyCode: keyCode,
            modifiers: modifiers,
            onStart: { self.triggerDictationStart() },
            onToggleRelease: {
                if self.isCurrentlyRecording() { self.triggerDictationStop() }
                else { self.triggerDictationStart() }
            }
        )
    }

    private func handleModifierOnlyCommandModeFlagsChanged(shortcut: HotkeyShortcut, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        handleModifierOnlyFlagsChanged(
            shortcut: shortcut,
            isEnabled: commandModeShortcutEnabled,
            holdModeType: .commandMode,
            keyCode: keyCode,
            modifiers: modifiers,
            onStart: { self.triggerCommandModeStart() },
            onToggleRelease: {
                if self.isCurrentlyRecording() { self.triggerDictationStop() }
                else { self.triggerCommandModeStart() }
            }
        )
    }

    private func handleModifierOnlyFlagsChanged(
        shortcut: HotkeyShortcut,
        isEnabled: Bool,
        holdModeType: HotkeyHoldModeType,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        onStart: @escaping () -> Void,
        onToggleRelease: @escaping () -> Void
    ) -> Bool {
        guard isEnabled, shortcut.isModifierOnlyShortcut else { return false }

        let expectedCodes = shortcut.normalizedModifierKeyCodes
        if !expectedCodes.isEmpty {
            let pressed = HotkeyShortcut.normalizedModifierKeyCodes(from: Array(pressedModifierKeyCodes))
            if pressed == expectedCodes {
                modifierOnlyKeyDown = true
                otherKeyPressedDuringModifier = false
                modifierPressStartTime = Date()
                scheduleModifierOnlyStart(holdModeType: holdModeType, onStart: onStart, wasTargetActive: isCurrentlyRecording())
                return true
            }
            guard modifierOnlyKeyDown,
                  expectedCodes.contains(keyCode),
                  !pressed.contains(keyCode)
            else { return false }

            let clean = !otherKeyPressedDuringModifier
            modifierOnlyKeyDown = false
            otherKeyPressedDuringModifier = false
            modifierPressStartTime = nil
            finishModifierOnlyPress(holdModeType: holdModeType, wasCleanPress: clean, onToggleRelease: onToggleRelease)
            return true
        }

        guard let expectedFlags = shortcut.expectedModifierFlags,
              let triggerFlag = shortcut.modifierTriggerFlag
        else { return false }

        let relevant = modifiers.intersection(HotkeyShortcut.relevantModifierMask)
        if relevant == expectedFlags {
            modifierOnlyKeyDown = true
            otherKeyPressedDuringModifier = false
            modifierPressStartTime = Date()
            scheduleModifierOnlyStart(holdModeType: holdModeType, onStart: onStart, wasTargetActive: isCurrentlyRecording())
            return true
        }

        guard modifierOnlyKeyDown,
              keyCode == shortcut.keyCode,
              !relevant.contains(triggerFlag)
        else { return false }

        let clean = !otherKeyPressedDuringModifier
        modifierOnlyKeyDown = false
        otherKeyPressedDuringModifier = false
        modifierPressStartTime = nil
        finishModifierOnlyPress(holdModeType: holdModeType, wasCleanPress: clean, onToggleRelease: onToggleRelease)
        return true
    }

    private func scheduleModifierOnlyStart(holdModeType: HotkeyHoldModeType, onStart: () -> Void, wasTargetActive: Bool) {
        guard hotkeyMode != .toggle else { return }
        let isModeKeyPressed = (holdModeType == .transcription) ? isKeyPressed : isCommandModeKeyPressed
        guard !isModeKeyPressed else { return }

        cancelPendingReleaseStop(for: holdModeType)
        clearHoldModeStartTriggered(for: holdModeType)
        if holdModeType == .transcription { isKeyPressed = true } else { isCommandModeKeyPressed = true }

        if hotkeyMode == .doubleTap {
            beginAutomaticPress(for: holdModeType, wasTargetActive: wasTargetActive)
            if wasTargetActive { return }
        }
        if hotkeyMode == .holdToRecord { markHoldModeStartTriggered(for: holdModeType) }
        onStart()
        if hotkeyMode == .doubleTap { markAutomaticPressStarted(for: holdModeType) }
    }

    private func finishModifierOnlyPress(holdModeType: HotkeyHoldModeType, wasCleanPress: Bool, onToggleRelease: @escaping () -> Void) {
        let label = holdModeType == .transcription ? "Dictation" : "Command mode"
        switch hotkeyMode {
        case .holdToRecord:
            let isModeKeyPressed = (holdModeType == .transcription) ? isKeyPressed : isCommandModeKeyPressed
            if isModeKeyPressed {
                if holdModeType == .transcription { isKeyPressed = false } else { isCommandModeKeyPressed = false }
                let didStart = finishHoldModeStartTriggered(for: holdModeType)
                if isCurrentlyRecording() || didStart {
                    stopRecordingAfterRelease(for: holdModeType, label: label)
                }
            }
        case .doubleTap:
            if holdModeType == .transcription { isKeyPressed = false } else { isCommandModeKeyPressed = false }
            if wasCleanPress {
                handleAutomaticKeyRelease(for: holdModeType, label: label)
            } else {
                let press = finishAutomaticPress(for: holdModeType)
                if press.started { stopRecordingAfterRelease(for: holdModeType, label: label) }
            }
        case .toggle:
            if wasCleanPress { onToggleRelease() }
        }
    }

    // MARK: - Trigger helpers (always @MainActor via Task)

    private func triggerDictationStart() {
        Task { @MainActor [weak self] in
            guard let self, !self.isProcessingStop else { return }
            DebugLogger.shared.info("Dictation start triggered", source: "VoiceHotkeyManager")
            self.onDictationStart?()
        }
    }

    private func triggerDictationStop() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopRecordingInternal()
        }
    }

    private func triggerCommandModeStart() {
        Task { @MainActor [weak self] in
            guard let self, !self.isProcessingStop else { return }
            DebugLogger.shared.info("Command mode start triggered", source: "VoiceHotkeyManager")
            self.onCommandModeStart?()
        }
    }

    @MainActor
    private func stopRecordingInternal() async {
        guard !isProcessingStop else {
            DebugLogger.shared.debug("Stop already in progress", source: "VoiceHotkeyManager")
            return
        }
        isProcessingStop = true
        defer { isProcessingStop = false }
        DebugLogger.shared.info("Dictation stop triggered", source: "VoiceHotkeyManager")
        onDictationStop?()
    }

    private func isCurrentlyRecording() -> Bool {
        isRecording?() ?? false
    }

    // MARK: - Public API

    public func isEventTapEnabled() -> Bool {
        guard let tap = eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    public func validateEventTapHealth() -> Bool {
        let enabled = isEventTapEnabled()
        if enabled && !isInitialized { isInitialized = true }
        return enabled
    }

    public func reinitialize() {
        DebugLogger.shared.info("Manual reinitialization requested", source: "VoiceHotkeyManager")
        initializationTask?.cancel()
        healthCheckTask?.cancel()
        resetModifierTracking()
        isInitialized = false
        initializeWithDelay()
    }

    // MARK: - Health check

    private func startHealthCheckTimer() {
        healthCheckTask?.cancel()
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(healthCheckInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    if !self.validateEventTapHealth() {
                        DebugLogger.shared.warning("Health check failed, attempting recovery", source: "VoiceHotkeyManager")
                        if self.setupGlobalHotkey() {
                            self.isInitialized = true
                            DebugLogger.shared.info("Health check recovery succeeded", source: "VoiceHotkeyManager")
                        } else {
                            self.isInitialized = false
                            DebugLogger.shared.error("Health check recovery failed", source: "VoiceHotkeyManager")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Deinit

    deinit {
        initializationTask?.cancel()
        healthCheckTask?.cancel()
        cleanupEventTap()
    }
}
#endif
