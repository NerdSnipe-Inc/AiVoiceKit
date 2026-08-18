// Sources/AiVoiceKit/macOS/Command/ActiveAppMonitor.swift
// Ported from FluidVoice — stripped of FluidVoice-specific imports.
#if os(macOS)
import AppKit
import Combine

/// Monitors the frontmost application so overlays and command handlers can
/// know the current user context without querying NSWorkspace on every event.
@MainActor
public final class ActiveAppMonitor: ObservableObject {
    public static let shared = ActiveAppMonitor()

    /// The currently active application (excludes Alric itself).
    @Published public private(set) var activeApp: NSRunningApplication?

    /// The icon of the currently active application.
    @Published public private(set) var activeAppIcon: NSImage?

    /// The bundle identifier of the currently active application.
    public var activeAppBundleID: String? { activeApp?.bundleIdentifier }

    /// The localised name of the currently active application.
    public var activeAppName: String? { activeApp?.localizedName }

    private var observer: NSObjectProtocol?
    private var isMonitoring = false

    private init() {}

    // MARK: - Lifecycle

    /// Start monitoring active-app changes.
    /// Call when showing overlays or when real-time app tracking is needed.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        updateActiveApp()

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateActiveApp()
            }
        }
    }

    /// Stop monitoring. Call when hiding overlays to conserve resources.
    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }

        activeApp = nil
        activeAppIcon = nil
    }

    /// One-shot refresh of the active app state.
    public func refreshActiveApp() {
        updateActiveApp()
    }

    // MARK: - Private

    private func updateActiveApp() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        // Never track ourselves
        guard front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        if activeApp?.bundleIdentifier != front.bundleIdentifier {
            activeApp = front
            activeAppIcon = front.icon
        }
    }
}
#endif
