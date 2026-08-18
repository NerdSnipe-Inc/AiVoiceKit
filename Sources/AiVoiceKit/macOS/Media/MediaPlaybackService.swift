#if os(macOS)
import Foundation

/// Pauses and resumes system media playback around dictation sessions.
///
/// Note: The MediaRemoteAdapter private framework used in FluidVoice is not available
/// as a Swift package dependency. This is a functional stub — `pauseIfPlaying()` always
/// returns `false`. Replace with a MediaRemoteAdapter integration once the framework is
/// added to the package.
@MainActor
public final class MediaPlaybackService {
    public static let shared = MediaPlaybackService()

    private init() {}

    /// Attempts to pause system media playback if something is currently playing.
    /// - Returns: `true` if media was paused (always `false` in this stub).
    public func pauseIfPlaying() async -> Bool {
        DebugLogger.shared.debug(
            "MediaPlaybackService: pauseIfPlaying — stub, no-op",
            source: "MediaPlaybackService"
        )
        return false
    }

    /// Resumes media playback only if this service previously paused it.
    /// - Parameter wePaused: Pass the value returned by `pauseIfPlaying()`.
    public func resumeIfWePaused(_ wePaused: Bool) async {
        guard wePaused else { return }
        DebugLogger.shared.debug(
            "MediaPlaybackService: resumeIfWePaused — stub, no-op",
            source: "MediaPlaybackService"
        )
    }
}
#endif
