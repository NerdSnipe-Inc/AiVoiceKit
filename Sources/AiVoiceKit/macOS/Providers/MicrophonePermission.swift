#if os(macOS)
import AVFoundation

/// Every `TranscriptionProvider.start(inputDeviceUID:)` implementation touches
/// `AVAudioEngine.inputNode` — without microphone authorization, `inputNode.outputFormat(forBus:)`
/// comes back with zero channels, and handing that format to `installTap` is a fatal AVAudioEngine
/// assertion (a hard crash), not a catchable Swift error. Call `ensureAuthorized()` before any of
/// that so a denied/undetermined mic permission surfaces as a normal thrown error instead.
enum MicrophonePermission {
    static func ensureAuthorized() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw NSError(
                    domain: "AiVoiceKit.Microphone", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone access was denied."]
                )
            }
        case .denied, .restricted:
            throw NSError(
                domain: "AiVoiceKit.Microphone", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access not authorized. Grant access in System Settings > Privacy > Microphone."]
            )
        @unknown default:
            throw NSError(
                domain: "AiVoiceKit.Microphone", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access is unavailable."]
            )
        }
    }
}
#endif
