// Sources/AiVoiceKit/macOS/Overlay/OverlayScreenResolver.swift
#if os(macOS)
import AppKit

/// Resolves which NSScreen the overlay should appear on (the screen under the pointer).
public enum OverlayScreenResolver {
    public static func screenForCurrentPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
#endif
