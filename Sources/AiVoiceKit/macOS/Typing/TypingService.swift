// Sources/AiVoiceKit/macOS/Typing/TypingService.swift
// Adapted from FluidVoice — wrapped in #if os(macOS), made public.
// Changes: removed SettingsStore.textInsertionMode (uses standard pipeline by default),
//          removed DictationLiteralOutputPlan (not in AiVoiceKit),
//          DebugLogger references unchanged (exists in Shared/).
#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

public final class TypingService: @unchecked Sendable {

    public init() {}

    // MARK: - Logging

    private static var isLoggingEnabled: Bool {
        if let env = ProcessInfo.processInfo.environment["ALRIC_TYPING_LOGS"], env == "1" { return true }
        return UserDefaults(suiteName: "com.nerdsnipe.alric.voice")?.bool(forKey: "alricEnableTypingLogs") ?? false
    }

    private func log(_ message: @autoclosure () -> String) {
        guard TypingService.isLoggingEnabled else { return }
        DebugLogger.shared.debug(message(), source: "TypingService")
    }

    // MARK: - Internal state

    private var isCurrentlyTyping = false

    // MARK: - Focus / Pasteboard snapshots

    private struct FocusSnapshot {
        let pid: pid_t
        let window: AXUIElement?
        let element: AXUIElement?
    }

    private struct PasteboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    private struct FocusedTextSnapshot {
        let pid: pid_t
        let bundleIdentifier: String?
        let value: String?
        let selectedRange: CFRange?
        let appScriptValue: String?
        let appScriptSelectedRange: CFRange?
    }

    private enum PasteVerificationResult: String {
        case appScriptContainsText = "appscript_contains_text"
        case appScriptCaretMovedExpectedDistance = "appscript_caret_moved_expected_distance"
        case fieldContainsText = "field_contains_text"
        case caretMovedExpectedDistance = "caret_moved_expected_distance"
        case timeout
        case unavailable
    }

    private static let focusSnapshotQueue = DispatchQueue(label: "TypingService.FocusSnapshot")
    private static let pasteboardSessionSemaphore = DispatchSemaphore(value: 1)
    private static let pasteboardRestoreQueue = DispatchQueue(label: "TypingService.PasteboardRestore", qos: .utility)
    private nonisolated(unsafe) static var focusSnapshot: FocusSnapshot?

    // MARK: - Focus helpers (shared static API)

    /// Captures the PID owning the currently focused accessibility element.
    /// More reliable than NSWorkspace.frontmostApplication for floating overlays.
    @discardableResult
    public static func captureSystemFocusedPID() -> pid_t? {
        guard AXIsProcessTrusted() else {
            storeFocusSnapshot(nil)
            return nil
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?

        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )
        guard result == .success, let focusedElementRef else {
            storeFocusSnapshot(nil)
            return nil
        }
        guard CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            storeFocusSnapshot(nil)
            return nil
        }

        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else {
            storeFocusSnapshot(nil)
            return nil
        }
        let appElement = AXUIElementCreateApplication(pid)
        let window = copyAXElementAttribute(from: appElement, attribute: kAXFocusedWindowAttribute as CFString)
            ?? copyAXElementAttribute(from: appElement, attribute: kAXMainWindowAttribute as CFString)
        storeFocusSnapshot(FocusSnapshot(pid: pid, window: window, element: element))
        return pid
    }

    /// Returns the text immediately before the caret in the currently focused text field.
    public static func textBeforeCursorInFocusedField() -> String {
        TypingService().captureTextBeforeCursorInFocusedField()
    }

    @discardableResult
    public static func restoreCapturedFocus(in pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let snapshot = loadFocusSnapshot(), snapshot.pid == pid else { return false }

        let appElement = AXUIElementCreateApplication(pid)

        if let window = snapshot.window {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, window)
            _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, window)
            usleep(40_000)
        }

        guard let element = snapshot.element else { return false }

        for _ in 0..<3 {
            let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if result == .success, isCurrentlyFocusedElement(element, expectedPID: pid) {
                return true
            }
            usleep(50_000)
        }

        return isCurrentlyFocusedElement(element, expectedPID: pid)
    }

    public static func isCapturedFocusStillActive(for pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(),
              let snapshot = loadFocusSnapshot(),
              snapshot.pid == pid,
              let element = snapshot.element
        else { return false }
        return isCurrentlyFocusedElement(element, expectedPID: pid)
    }

    /// Best-effort: activates the app with the given PID.
    @discardableResult
    public static func activateApp(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if let selfBundleID = Bundle.main.bundleIdentifier,
           let targetBundleID = app.bundleIdentifier,
           selfBundleID == targetBundleID { return false }
        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    // MARK: - Public API

    public func typeTextInstantly(_ text: String) {
        typeTextInstantly(text, preferredTargetPID: nil)
    }

    public func typeTextInstantly(_ text: String, preferredTargetPID: pid_t?) {
        let requestedAt = ProcessInfo.processInfo.systemUptime
        bench("request chars=\(text.count) preferredPID=\(preferredTargetPID.map { String($0) } ?? "nil")")
        log("[TypingService] typeTextInstantly called, text length: \(text.count)")

        guard !text.isEmpty else {
            bench("request_return reason=empty_text")
            log("[TypingService] ERROR: Empty text, aborting")
            return
        }

        guard !isCurrentlyTyping else {
            bench("request_return reason=already_typing")
            log("[TypingService] WARNING: Already typing, skipping")
            return
        }

        guard AXIsProcessTrusted() else {
            bench("request_return reason=accessibility_not_trusted")
            log("[TypingService] ERROR: Accessibility permissions required")
            return
        }

        isCurrentlyTyping = true

        // Settle delay: give time for focus to transfer back to the target app
        // when no preferred PID is provided.
        let settleDelayMs = preferredTargetPID == nil ? 200 : 0

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                self.isCurrentlyTyping = false
                self.bench("complete totalMs=\(Self.elapsedMs(since: requestedAt))")
            }

            if settleDelayMs > 0 {
                usleep(useconds_t(settleDelayMs * 1000))
            }
            self.bench("settle_done delayMs=\(settleDelayMs)")
            self.insertTextInstantly(text, preferredTargetPID: preferredTargetPID)
        }
    }

    // MARK: - Benchmarking

    private func bench(_ message: String) {
        DebugLogger.shared.benchmark("TYPING_BENCH", message: message, source: "TypingBenchmark")
    }

    private static func elapsedMs(since start: TimeInterval) -> Int {
        Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded())
    }

    private static func elapsedMs(from start: TimeInterval, to end: TimeInterval) -> Int {
        Int(((end - start) * 1000).rounded())
    }

    // MARK: - Insertion pipeline

    private func insertTextInstantly(_ text: String, preferredTargetPID: pid_t?) {
        log("[TypingService] insertTextInstantly: \(text.count) chars")

        // Fast path: CGEvent targeted at the preferred PID (e.g. the app that had focus
        // before the voice overlay appeared).
        if let preferredTargetPID, preferredTargetPID > 0 {
            log("[TypingService] Trying CGEvent insertion to preferred PID \(preferredTargetPID)")
            if insertTextBulkInstant(text, targetPID: preferredTargetPID) {
                log("[TypingService] SUCCESS: preferred-PID CGEvent insertion")
                return
            }
        }

        // Determine focused element PID
        let focusInfo = getSystemFocusedElementAndPID()

        // Primary: CGEvent targeting the currently focused PID
        if let focusedPID = focusInfo?.pid {
            log("[TypingService] Trying CGEvent insertion to focused PID \(focusedPID)")
            if insertTextBulkInstant(text, targetPID: focusedPID) {
                log("[TypingService] SUCCESS: focused-PID CGEvent insertion")
                return
            }
        }

        // Secondary: Accessibility API insertion
        log("[TypingService] Trying Accessibility insertion")
        if insertTextViaAccessibility(text) {
            log("[TypingService] SUCCESS: Accessibility insertion")
            return
        }

        // HID fallback when no PID is available
        if focusInfo?.pid == nil {
            log("[TypingService] Trying HID CGEvent insertion")
            if insertTextBulkHIDInstant(text) {
                log("[TypingService] SUCCESS: HID CGEvent insertion")
                return
            }
        }

        // Clipboard fallback
        log("[TypingService] Trying clipboard fallback")
        if insertTextViaClipboard(text) {
            log("[TypingService] SUCCESS: clipboard insertion")
            return
        }

        // Last resort: character by character
        log("[TypingService] WARNING: falling back to char-by-char")
        for char in text {
            typeCharacter(char)
            usleep(1_000)
        }
    }

    // MARK: - CGEvent insertion

    private static let cgEventUnicodeChunkSize = 200

    private static var pasteVirtualKeyCode: CGKeyCode {
        virtualKeyCode(for: "v", qwertyFallback: 9)
    }

    private static func virtualKeyCode(for character: Character, qwertyFallback: CGKeyCode) -> CGKeyCode {
        if Thread.isMainThread {
            return tisLookup(for: character, qwertyFallback: qwertyFallback)
        }
        var result = qwertyFallback
        DispatchQueue.main.sync {
            result = tisLookup(for: character, qwertyFallback: qwertyFallback)
        }
        return result
    }

    private static func tisLookup(for character: Character, qwertyFallback: CGKeyCode) -> CGKeyCode {
        guard let targetScalar = character.unicodeScalars.first else { return qwertyFallback }
        guard let sourceRef = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawPtr = TISGetInputSourceProperty(sourceRef, kTISPropertyUnicodeKeyLayoutData)
        else { return qwertyFallback }

        let layoutData = Unmanaged<CFData>.fromOpaque(rawPtr).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> CGKeyCode in
            guard let layoutPtr = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return qwertyFallback
            }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let kbType = UInt32(LMGetKbdType())
            for keyCode: UInt16 in 0..<128 {
                deadKeyState = 0
                length = 0
                let status = UCKeyTranslate(
                    layoutPtr, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    kbType, UInt32(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState, chars.count, &length, &chars
                )
                guard status == noErr, length > 0 else { continue }
                if Unicode.Scalar(chars[0]) == targetScalar { return CGKeyCode(keyCode) }
            }
            return qwertyFallback
        }
    }

    private func insertTextBulkInstant(_ text: String, targetPID: pid_t) -> Bool {
        guard targetPID > 0 else { return false }
        let utf16Array = Array(text.utf16)
        return postUnicodeChunks(utf16Array, destinationDescription: "PID \(targetPID)") { event in
            event.postToPid(targetPID)
        }
    }

    private func insertTextBulkHIDInstant(_ text: String) -> Bool {
        let utf16Array = Array(text.utf16)
        return postUnicodeChunks(utf16Array, destinationDescription: "HID tap") { event in
            event.post(tap: .cghidEventTap)
        }
    }

    private func postUnicodeChunks(
        _ utf16Array: [UInt16],
        destinationDescription: String,
        post: (CGEvent) -> Void
    ) -> Bool {
        guard !utf16Array.isEmpty else { return true }
        let chunkCount: Int = utf16Array.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            var chunkStart = 0
            var count = 0
            while chunkStart < buffer.count {
                let chunkEnd = Self.unicodeChunkEnd(in: utf16Array, start: chunkStart)
                let chunkLength = chunkEnd - chunkStart
                guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                else { return -1 }
                let chunkPointer = baseAddress.advanced(by: chunkStart)
                keyDown.keyboardSetUnicodeString(stringLength: chunkLength, unicodeString: chunkPointer)
                keyUp.keyboardSetUnicodeString(stringLength: chunkLength, unicodeString: chunkPointer)
                post(keyDown)
                post(keyUp)
                chunkStart = chunkEnd
                count += 1
            }
            return count
        }
        guard chunkCount >= 0 else { return false }
        log("[TypingService] Posted \(chunkCount) unicode chunk(s) to \(destinationDescription)")
        return true
    }

    private static func unicodeChunkEnd(in utf16Array: [UInt16], start: Int) -> Int {
        var end = min(start + cgEventUnicodeChunkSize, utf16Array.count)
        if end < utf16Array.count, end > start,
           isHighSurrogate(utf16Array[end - 1]),
           isLowSurrogate(utf16Array[end]) { end -= 1 }
        return max(end, start + 1)
    }

    private static func isHighSurrogate(_ v: UInt16) -> Bool { (0xd800...0xdbff).contains(v) }
    private static func isLowSurrogate(_ v: UInt16) -> Bool { (0xdc00...0xdfff).contains(v) }

    // MARK: - Clipboard insertion

    private func insertTextViaClipboard(_ text: String) -> Bool {
        log("[TypingService] clipboard-based insertion")
        return withTemporaryPasteboardString(text, restoreDelayMicros: 5_000_000) {
            let vKey = Self.pasteVirtualKeyCode
            guard let cmdVDown = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: true),
                  let cmdVUp = CGEvent(keyboardEventSource: nil, virtualKey: vKey, keyDown: false)
            else {
                self.log("[TypingService] ERROR: Failed to create Cmd+V events")
                return false
            }
            cmdVDown.flags = .maskCommand
            cmdVUp.flags = .maskCommand
            cmdVDown.post(tap: .cghidEventTap)
            usleep(10_000)
            cmdVUp.post(tap: .cghidEventTap)
            return true
        }
    }

    // MARK: - Pasteboard helpers

    private func capturePasteboardSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [PasteboardItemSnapshot] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dataByType[type] = data }
            }
            return PasteboardItemSnapshot(dataByType: dataByType)
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    private func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let restoredItems = snapshot.items.map { snap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snap.dataByType { item.setData(data, forType: type) }
            return item
        }
        _ = pasteboard.writeObjects(restoredItems)
    }

    private func withTemporaryPasteboardString(
        _ text: String,
        restoreDelayMicros: useconds_t,
        action: () -> Bool
    ) -> Bool {
        Self.pasteboardSessionSemaphore.wait()
        var releasesPasteboardSessionOnReturn = true
        defer {
            if releasesPasteboardSessionOnReturn { Self.pasteboardSessionSemaphore.signal() }
        }

        let pasteboard = NSPasteboard.general
        let snapshot = capturePasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restorePasteboardSnapshot(snapshot, to: pasteboard)
            return false
        }
        let temporaryChangeCount = pasteboard.changeCount
        let focusedTextSnapshot = captureFocusedTextSnapshot()
        let actionResult = action()
        guard actionResult else {
            restorePasteboardSnapshot(snapshot, to: pasteboard)
            return false
        }

        releasesPasteboardSessionOnReturn = false
        Self.pasteboardRestoreQueue.async {
            defer { Self.pasteboardSessionSemaphore.signal() }
            _ = self.waitForFocusedTextVerification(
                from: focusedTextSnapshot,
                expectedText: text,
                timeoutMicros: restoreDelayMicros
            )
            if pasteboard.changeCount == temporaryChangeCount || pasteboard.string(forType: .string) == text {
                self.restorePasteboardSnapshot(snapshot, to: pasteboard)
                self.log("[TypingService] Restored previous clipboard snapshot")
            } else {
                self.log("[TypingService] Skipped clipboard restore — clipboard changed externally")
            }
        }
        return true
    }

    // MARK: - Accessibility insertion

    private func insertTextViaAccessibility(_ text: String) -> Bool {
        log("[TypingService] Accessibility insertion")
        if let element = getFocusedTextElement() {
            if tryAllTextInsertionMethods(element, text) { return true }
        }
        if let element = findTextElementInFrontmostApp() {
            if tryAllTextInsertionMethods(element, text) { return true }
        }
        if let element = findKeyboardFocusedElement() {
            if tryAllTextInsertionMethods(element, text) { return true }
        }
        return false
    }

    private func getFocusedTextElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let focusedElement else { return nil }
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focusedElement, to: AXUIElement.self)
    }

    private func findTextElementInFrontmostApp() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        return findTextElementRecursively(appElement, depth: 0, maxDepth: 8)
    }

    private func findTextElementRecursively(_ element: AXUIElement, depth: Int, maxDepth: Int) -> AXUIElement? {
        if depth > maxDepth { return nil }
        if let role = getElementAttribute(element, kAXRoleAttribute as CFString) {
            let textRoles = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXStaticText"]
            if textRoles.contains(role) { return element }
        }
        var children: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if result == .success, let childrenArray = children as? [AXUIElement] {
            for child in childrenArray.prefix(10) {
                if let found = findTextElementRecursively(child, depth: depth + 1, maxDepth: maxDepth) {
                    return found
                }
            }
        }
        return nil
    }

    private func findKeyboardFocusedElement() -> AXUIElement? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let focusedElement else { return nil }
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(focusedElement, to: AXUIElement.self)
    }

    private func tryAllTextInsertionMethods(_ element: AXUIElement, _ text: String) -> Bool {
        if insertTextAtCursorUsingSelectedRange(element, text) { return true }
        if setTextViaValue(element, text) { return true }
        if setTextViaSelection(element, text) { return true }
        if insertTextAtInsertionPoint(element, text) { return true }
        return false
    }

    private func getElementAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let stringValue = value as? String else { return nil }
        return stringValue
    }

    private func getSystemFocusedElementAndPID() -> (element: AXUIElement, pid: pid_t)? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        guard result == .success, let focusedElementRef else { return nil }
        guard CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0 else { return nil }
        return (element: element, pid: pid)
    }

    private func getElementStringValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard result == .success, let str = value as? String else { return nil }
        return str
    }

    private func getSelectedTextRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let axValue = value else { return nil }
        guard CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        let ok = AXValueGetValue(unsafeBitCast(axValue, to: AXValue.self), .cfRange, &range)
        return ok ? range : nil
    }

    private func insertTextAtCursorUsingSelectedRange(_ element: AXUIElement, _ text: String) -> Bool {
        guard let currentValue = getElementStringValue(element) else { return false }
        guard var range = getSelectedTextRange(element) else { return false }
        let nsString = currentValue as NSString
        let maxLen = nsString.length
        let safeLoc = max(0, min(range.location, maxLen))
        let safeLen = max(0, min(range.length, maxLen - safeLoc))
        range = CFRange(location: safeLoc, length: safeLen)
        let mutable = NSMutableString(string: currentValue)
        mutable.replaceCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, mutable as CFString)
        guard setResult == .success else { return false }
        let insertedLen = (text as NSString).length
        var newRange = CFRange(location: range.location + insertedLen, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
        log("[TypingService] SUCCESS: inserted text using selected range + value")
        return true
    }

    private func setTextViaValue(_ element: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    private func setTextViaSelection(_ element: AXUIElement, _ text: String) -> Bool {
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, "" as CFString)
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func insertTextAtInsertionPoint(_ element: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    private func typeCharacter(_ char: Character) {
        let utf16Array = Array(String(char).utf16)
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }
        keyDown.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyUp.keyboardSetUnicodeString(stringLength: utf16Array.count, unicodeString: utf16Array)
        keyDown.post(tap: .cghidEventTap)
        usleep(2_000)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: - Paste verification (used to know when to restore pasteboard)

    private func captureFocusedTextSnapshot() -> FocusedTextSnapshot? {
        guard let focusInfo = getSystemFocusedElementAndPID() else { return nil }
        let bundleIdentifier = NSRunningApplication(processIdentifier: focusInfo.pid)?.bundleIdentifier
        let appScriptSnapshot = captureAppScriptTextSnapshot(forBundleIdentifier: bundleIdentifier)
        return FocusedTextSnapshot(
            pid: focusInfo.pid,
            bundleIdentifier: bundleIdentifier,
            value: getElementStringValue(focusInfo.element),
            selectedRange: getSelectedTextRange(focusInfo.element),
            appScriptValue: appScriptSnapshot?.value,
            appScriptSelectedRange: appScriptSnapshot?.selectedRange
        )
    }

    private func captureTextBeforeCursorInFocusedField() -> String {
        guard let snapshot = captureFocusedTextSnapshot() else { return "" }
        if let scriptValue = snapshot.appScriptValue, let scriptRange = snapshot.appScriptSelectedRange {
            return Self.prefix(in: scriptValue, before: scriptRange.location)
        }
        if let value = snapshot.value, let selectedRange = snapshot.selectedRange {
            return Self.prefix(in: value, before: selectedRange.location)
        }
        return ""
    }

    private static func prefix(in text: String, before location: Int) -> String {
        let nsText = text as NSString
        let safeLocation = max(0, min(location, nsText.length))
        guard safeLocation > 0 else { return "" }
        return nsText.substring(with: NSRange(location: 0, length: safeLocation))
    }

    private struct AppScriptTextSnapshot {
        let value: String?
        let selectedRange: CFRange?
    }

    private func waitForFocusedTextVerification(
        from snapshot: FocusedTextSnapshot?,
        expectedText: String,
        timeoutMicros: useconds_t
    ) -> PasteVerificationResult {
        guard let snapshot else {
            usleep(timeoutMicros)
            return .unavailable
        }
        let pollMicros: useconds_t = 50_000
        let expectedLength = max(1, (expectedText as NSString).length)
        let tolerance = max(2, expectedLength / 5)
        var waited: useconds_t = 0

        while waited < timeoutMicros {
            usleep(pollMicros)
            waited += pollMicros
            guard let current = captureFocusedTextSnapshot(), current.pid == snapshot.pid else { continue }

            if let currentValue = current.appScriptValue,
               currentValue.contains(expectedText), currentValue != snapshot.appScriptValue {
                return .appScriptContainsText
            }
            if let before = snapshot.appScriptSelectedRange, let after = current.appScriptSelectedRange,
               after.length == 0, abs(after.location - (before.location + expectedLength)) <= tolerance {
                return .appScriptCaretMovedExpectedDistance
            }
            if let currentValue = current.value,
               currentValue.contains(expectedText), currentValue != snapshot.value {
                return .fieldContainsText
            }
            if let before = snapshot.selectedRange, let after = current.selectedRange,
               after.length == 0, abs(after.location - (before.location + expectedLength)) <= tolerance {
                return .caretMovedExpectedDistance
            }
        }
        return .timeout
    }

    private func captureAppScriptTextSnapshot(forBundleIdentifier bundleIdentifier: String?) -> AppScriptTextSnapshot? {
        switch bundleIdentifier {
        case "com.apple.dt.Xcode":  return captureXcodeScriptSnapshot()
        case "com.apple.Notes":     return captureNotesScriptSnapshot()
        default:                    return nil
        }
    }

    private func captureXcodeScriptSnapshot() -> AppScriptTextSnapshot? {
        guard let value = runAppleScript("""
        tell application "Xcode"
            if (count of source documents) is 0 then return ""
            return text of source document 1
        end tell
        """) else { return nil }
        let selectedRange = runAppleScript("""
        tell application "Xcode"
            if (count of source documents) is 0 then return ""
            return selected character range of source document 1
        end tell
        """).flatMap(parseAppleScriptRange)
        return AppScriptTextSnapshot(value: value, selectedRange: selectedRange)
    }

    private func captureNotesScriptSnapshot() -> AppScriptTextSnapshot? {
        guard let value = runAppleScript("""
        tell application "Notes"
            set selectedNotes to selection as list
            if (count of selectedNotes) is 0 then return ""
            set noteId to id of item 1 of selectedNotes
            return plaintext of note id noteId
        end tell
        """) else { return nil }
        return AppScriptTextSnapshot(value: value, selectedRange: nil)
    }

    private func runAppleScript(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    private func parseAppleScriptRange(_ rawValue: String) -> CFRange? {
        let components = rawValue.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard components.count == 2 else { return nil }
        let start = max(0, components[0] - 1)
        let end = max(start, components[1] - 1)
        return CFRange(location: start, length: end - start)
    }

    // MARK: - AXUIElement helpers (static)

    private static func storeFocusSnapshot(_ snapshot: FocusSnapshot?) {
        focusSnapshotQueue.sync { Self.focusSnapshot = snapshot }
    }

    private static func loadFocusSnapshot() -> FocusSnapshot? {
        focusSnapshotQueue.sync { Self.focusSnapshot }
    }

    private static func copyAXElementAttribute(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func isCurrentlyFocusedElement(_ expectedElement: AXUIElement, expectedPID: pid_t) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        guard result == .success, let focusedElementRef else { return false }
        guard CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else { return false }
        let currentElement = unsafeBitCast(focusedElementRef, to: AXUIElement.self)
        if CFEqual(currentElement, expectedElement) { return true }
        var currentPID: pid_t = 0
        AXUIElementGetPid(currentElement, &currentPID)
        guard currentPID == expectedPID else { return false }
        var currentRoleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(currentElement, kAXRoleAttribute as CFString, &currentRoleRef)
        guard roleResult == .success, let currentRole = currentRoleRef as? String else { return false }
        return ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXWebArea", "AXGroup"].contains(currentRole)
    }
}
#endif
