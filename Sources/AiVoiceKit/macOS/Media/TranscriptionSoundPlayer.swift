#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation

/// Plays start/stop chime sounds around dictation sessions.
/// Sounds are loaded from `Bundle.module` (package resources).
public final class TranscriptionSoundPlayer: @unchecked Sendable {
    public nonisolated(unsafe) static let shared = TranscriptionSoundPlayer()

    private let playbackQueue = DispatchQueue(label: "com.nerdsnipe.alric.voice.transcription-sounds", qos: .userInteractive)
    private var players: [String: AVAudioPlayer] = [:]
    private var savedSystemVolume: Float?

    private init() {}

    // MARK: - Public API

    public func playStartSound() {
        let settings = VoiceSettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        play(
            soundName: "voice_start",
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    public func playStopSound() {
        let settings = VoiceSettingsStore.shared
        guard settings.enableTranscriptionSounds else { return }
        play(
            soundName: "voice_end",
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview start sound at the current volume setting (used in Settings UI).
    public func playPreview() {
        let settings = VoiceSettingsStore.shared
        play(
            soundName: "voice_start",
            desiredVolume: settings.transcriptionSoundVolume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    /// Preview start sound at a specific volume (used when a volume slider is released).
    public func playPreviewAtVolume(_ volume: Float) {
        let settings = VoiceSettingsStore.shared
        play(
            soundName: "voice_start",
            desiredVolume: volume,
            independentVolume: settings.transcriptionSoundIndependentVolume
        )
    }

    // MARK: - Private playback

    private func play(
        soundName: String,
        desiredVolume: Float,
        independentVolume: Bool
    ) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.benchmark(
            "APP_BENCH",
            message: "sound_play_request sound=\(soundName)",
            source: "TranscriptionSoundPlayer"
        )

        guard let url = Bundle.module.url(forResource: soundName, withExtension: "m4a") else {
            DebugLogger.shared.error("Missing sound resource: \(soundName).m4a", source: "TranscriptionSoundPlayer")
            return
        }

        playbackQueue.async { [weak self] in
            self?.playOnPlaybackQueue(
                soundName: soundName,
                url: url,
                desiredVolume: desiredVolume,
                independentVolume: independentVolume,
                startedAt: startedAt
            )
        }
    }

    private func playOnPlaybackQueue(
        soundName: String,
        url: URL,
        desiredVolume: Float,
        independentVolume: Bool,
        startedAt: TimeInterval
    ) {
        if independentVolume {
            let currentVol = Self.getSystemVolume()
            guard currentVol > 0.001 else { return }
            savedSystemVolume = currentVol
            Self.setSystemVolume(desiredVolume)
        }

        do {
            let player: AVAudioPlayer
            if let existing = players[soundName] {
                player = existing
            } else {
                player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[soundName] = player
            }

            player.currentTime = 0
            player.volume = independentVolume ? 1.0 : desiredVolume
            player.play()

            DebugLogger.shared.benchmark(
                "APP_BENCH",
                message: "sound_play_dispatched sound=\(soundName) elapsedMs=\(Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded()))",
                source: "TranscriptionSoundPlayer"
            )

            if independentVolume, let saved = savedSystemVolume {
                let duration = player.duration
                playbackQueue.asyncAfter(deadline: .now() + duration + 0.05) { [weak self] in
                    Self.setSystemVolume(saved)
                    self?.savedSystemVolume = nil
                }
            }
        } catch {
            if let saved = savedSystemVolume {
                Self.setSystemVolume(saved)
                savedSystemVolume = nil
            }
            DebugLogger.shared.error(
                "Failed to play \(soundName).m4a: \(error.localizedDescription)",
                source: "TranscriptionSoundPlayer"
            )
        }
    }

    // MARK: - CoreAudio system volume

    private static func getDefaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    public static func getSystemVolume() -> Float {
        guard let deviceID = getDefaultOutputDeviceID() else { return 1.0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume = Float32(1.0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return 1.0 }
        return volume
    }

    private static func setSystemVolume(_ volume: Float) {
        guard let deviceID = getDefaultOutputDeviceID() else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var vol = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &vol)
        if status != noErr {
            DebugLogger.shared.error("Failed to set system volume: OSStatus \(status)", source: "TranscriptionSoundPlayer")
        }
    }
}
#endif
