// Sources/AiVoiceKit/macOS/Overlay/NotchOverlayManager.swift
#if os(macOS)
import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

// MARK: - Internal overlay state (shared with hosted SwiftUI views)

/// Observable state object passed into the hosted overlay views.
/// Internal to the package — app-target views observe VoiceEngineMacOS directly.
@MainActor
final class OverlayContentState: ObservableObject {
    static let shared = OverlayContentState()

    @Published var transcript: String = ""
    @Published var mode: RecordingMode = .dictation
    @Published var isProcessing: Bool = false

    private init() {}

    func reset() {
        transcript = ""
        isProcessing = false
    }
}

// MARK: - Package-internal notch content view

private struct NotchLiveView: View {
    @ObservedObject var state: OverlayContentState

    var modeLabel: String {
        switch state.mode {
        case .dictation: return "Dictation"
        case .command:   return "Command"
        case .edit:      return "Edit"
        case .fileTranscription: return "Transcription"
        }
    }

    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            // Pulse indicator
            Circle()
                .fill(state.isProcessing ? Color("alricSelection") : Color("alricTextMuted"))
                .frame(width: 8, height: 8)
                .opacity(0.9)

            VStack(alignment: .leading, spacing: 2) {
                Text(modeLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                if state.isProcessing {
                    Text("Processing…")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else if state.transcript.isEmpty {
                    Text("Listening…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(state.transcript)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 240, maxWidth: 360)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - Package-internal bottom pill view

private struct BottomPillView: View {
    @ObservedObject var state: OverlayContentState
    var onTap: (() -> Void)?

    var modeLabel: String {
        switch state.mode {
        case .dictation: return "Dictation"
        case .command:   return "Command"
        case .edit:      return "Edit"
        case .fileTranscription: return "Transcription"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.isProcessing ? Color("alricSelection") : Color("alricTextMuted"))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(modeLabel)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                if state.isProcessing {
                    Text("Processing…")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else if state.transcript.isEmpty {
                    Text("Listening…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(state.transcript)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: NSColor.controlBackgroundColor).opacity(0.95))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - Bottom overlay NSPanel controller

@MainActor
private final class BottomOverlayPanelController {
    private var panel: NSPanel?

    func show(state: OverlayContentState, settings: VoiceSettingsStore, onTap: (() -> Void)?) {
        guard panel == nil else { return }

        let screen = OverlayScreenResolver.screenForCurrentPointer()
            ?? NSScreen.main
            ?? NSScreen.screens[0]

        let pillWidth: CGFloat
        switch settings.overlaySize {
        case .compact:  pillWidth = 300
        case .standard: pillWidth = 420
        case .large:    pillWidth = 540
        }
        let pillHeight: CGFloat = 54
        let yOffset = max(40, settings.overlayBottomOffset)

        let origin = CGPoint(
            x: screen.frame.midX - pillWidth / 2,
            y: screen.frame.minY + yOffset
        )
        let frame = CGRect(origin: origin, size: CGSize(width: pillWidth, height: pillHeight))

        let content = BottomPillView(state: state, onTap: onTap)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: frame.size)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // shadow is in SwiftUI view
        p.ignoresMouseEvents = false
        p.contentView = hosting
        p.alphaValue = 0
        p.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
        self.panel = p
    }

    func hide(completion: @escaping @MainActor () -> Void) {
        guard let p = panel else { completion(); return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                p.close()
                completion()
            }
        }
    }
}

// MARK: - NotchOverlayManager

/// Manages the floating overlay shown during voice recording.
///
/// Routes to the notch overlay (DynamicNotchKit) or a bottom pill (NSPanel)
/// based on `VoiceSettingsStore.shared.overlayPosition`.
///
/// Call `show(mode:)`, `showProcessing()`, and `hide()` from `VoiceEngineMacOS.setupOverlayObservation()`.
@MainActor
public final class NotchOverlayManager {
    public static let shared = NotchOverlayManager()

    // MARK: - Public

    /// Called when the user taps the overlay (for dismiss / toggle use cases).
    public var onOverlayTapped: (() -> Void)?

    // MARK: - Private state

    private typealias AlricNotch = DynamicNotch<NotchLiveView, EmptyView, EmptyView, EmptyView>
    private var activeNotch: AlricNotch?
    private let bottomController = BottomOverlayPanelController()
    private var isVisible = false
    private var isBottomVisible = false

    private init() {}

    // MARK: - Public API

    /// Show overlay for the given recording mode.
    public func show(mode: RecordingMode) {
        let contentState = OverlayContentState.shared
        contentState.mode = mode
        contentState.isProcessing = false
        showOverlay()
    }

    /// Switch overlay to processing state (spinner/indicator). Re-shows if hidden.
    public func showProcessing() {
        OverlayContentState.shared.isProcessing = true
        if !isVisible {
            showOverlay()
        }
    }

    /// Dismiss the active overlay.
    public func hide() {
        guard isVisible else { return }
        isVisible = false
        Task { await performHide() }
    }

    /// Forward live transcript text into the overlay (no-op if preview is disabled).
    public func updateTranscript(_ text: String) {
        guard VoiceSettingsStore.shared.enableStreamingPreview else { return }
        OverlayContentState.shared.transcript = text
    }

    // MARK: - Private routing

    private func showOverlay() {
        isVisible = true
        if VoiceSettingsStore.shared.overlayPosition == .bottom {
            showBottom()
        } else {
            showNotch()
        }
    }

    private func showNotch() {
        guard activeNotch == nil else { return }
        let contentState = OverlayContentState.shared
        let tapped = onOverlayTapped
        let notch = DynamicNotch(hoverBehavior: [], style: .auto) {
            NotchLiveView(state: contentState, onTap: tapped)
        }
        self.activeNotch = notch
        let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.screens[0]
        Task { await notch.expand(on: screen) }
    }

    private func showBottom() {
        guard !isBottomVisible else { return }
        isBottomVisible = true
        bottomController.show(
            state: OverlayContentState.shared,
            settings: VoiceSettingsStore.shared,
            onTap: onOverlayTapped
        )
    }

    private func performHide() async {
        // Hide notch
        if let notch = activeNotch {
            await notch.hide()
            activeNotch = nil
        }

        // Hide bottom panel
        if isBottomVisible {
            isBottomVisible = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                bottomController.hide { continuation.resume() }
            }
        }

        OverlayContentState.shared.reset()
    }
}
#endif
