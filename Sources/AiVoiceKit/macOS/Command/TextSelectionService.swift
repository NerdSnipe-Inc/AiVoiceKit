// Sources/AiVoiceKit/macOS/Command/TextSelectionService.swift
// Ported from FluidVoice — DebugLogger/FileLogger replaced with os.log.
#if os(macOS)
import AppKit
import ApplicationServices
import Foundation
import os.log

/// Reads the currently selected text from the frontmost application using
/// Accessibility APIs.  Requires the Accessibility permission entitlement.
public final class TextSelectionService {
    public nonisolated(unsafe) static let shared = TextSelectionService()
    private static let logger = Logger(subsystem: "com.alric.voicekit", category: "TextSelectionService")

    private init() {}

    // MARK: - Public

    /// Returns the selected text in the frontmost app, or `nil` if unavailable.
    public func getSelectedText() -> String? {
        diag("Selection capture start")

        guard AXIsProcessTrusted() else {
            Self.logger.error("Accessibility permissions not granted")
            diag("Selection capture failed: Accessibility permissions not granted")
            return nil
        }

        // 1. System-wide focused element
        if let focused = getFocusedElement() {
            if let text = getSelectedText(from: focused) {
                diag("Selection capture success via system focused element (chars=\(text.count))")
                return text
            }
            diag("System focused element returned no selected text")
        }

        // 2. Fallback: frontmost app's focused element
        if let front = NSWorkspace.shared.frontmostApplication {
            diag("Trying frontmost app fallback: \(front.bundleIdentifier ?? front.localizedName ?? "unknown") pid=\(front.processIdentifier)")
            let appElement = AXUIElementCreateApplication(front.processIdentifier)
            if let focused = getFocusedElement(from: appElement) {
                if let text = getSelectedText(from: focused) {
                    diag("Selection capture success via frontmost app focused element (chars=\(text.count))")
                    return text
                }
                diag("Frontmost app focused element returned no selected text")
            } else {
                diag("Frontmost app fallback could not resolve focused element")
            }
        }

        diag("Selection capture failed: no selected text found")
        return nil
    }

    // MARK: - Private helpers

    private func getFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private func getFocusedElement(from appElement: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    private func getSelectedText(from element: AXUIElement) -> String? {
        // Primary: kAXSelectedTextAttribute
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &valueRef) == .success,
           let text = valueRef as? String
        {
            diag("kAXSelectedTextAttribute succeeded (chars=\(text.count))")
            return text
        }

        diag("kAXSelectedTextAttribute unavailable — trying selected range fallback")

        // Fallback: reconstruct from kAXSelectedTextRangeAttribute + kAXValueAttribute
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else {
            diag("kAXSelectedTextRangeAttribute unavailable")
            return nil
        }

        let axValue = unsafeBitCast(rangeRef, to: AXValue.self)
        var cfRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &cfRange),
              cfRange.location != kCFNotFound,
              cfRange.length > 0
        else {
            diag("Selected range empty")
            return nil
        }

        var fullRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fullRef) == .success,
              let fullText = fullRef as? String
        else {
            diag("kAXValueAttribute unavailable for range extraction")
            return nil
        }

        let nsText = fullText as NSString
        guard cfRange.location >= 0,
              cfRange.location + cfRange.length <= nsText.length
        else {
            diag("Selected range out of bounds (textLen=\(nsText.length), location=\(cfRange.location), length=\(cfRange.length))")
            return nil
        }

        let extracted = nsText.substring(with: NSRange(location: cfRange.location, length: cfRange.length))
        diag("Selected range extraction succeeded (chars=\(extracted.count))")
        return extracted
    }

    private func diag(_ message: String) {
        Self.logger.debug("\(message, privacy: .public)")
    }
}
#endif
