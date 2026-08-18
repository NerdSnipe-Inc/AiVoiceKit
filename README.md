# AiVoiceKit

A Swift package providing on-device voice dictation, command routing, and AI-assisted rewriting for macOS (iOS/visionOS platform stubs included for future work).

Originally ported from [FluidVoice](https://github.com/altic-dev/FluidVoice) by Aether AI Studio / altic-dev, and adapted for use as a standalone, host-app-agnostic package. AiVoiceKit has no dependency on Alric or any other host application — the host wires it up via a plain callback-based `VoiceEngine` protocol.

## What it does

- **Local ASR** via Apple's built-in `SFSpeechRecognizer`/`SpeechAnalyzer` (zero download), or downloadable on-device models: Whisper (Tiny–Large via [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper)), Parakeet Flash/TDT v2/v3, Nemotron Speech, and Cohere Transcribe (all via [FluidAudio](https://github.com/altic-dev/FluidAudio), CoreML, arm64 macOS)
- **Global hotkey activation** — hold-to-record, toggle, or double-tap, with configurable shortcuts for dictation, command mode, edit mode, cancel, and paste-last-transcription
- **Command routing** — text prefixed with a configurable wake word (e.g. `"Alric, summarize this"`) is routed to a host-supplied callback instead of being typed into the frontmost app
- **Edit mode** — rewrite selected text in the frontmost app via a host-supplied AI callback
- **Notch/bottom overlay** — live transcript, waveform, and mode indicator via [DynamicNotchKit](https://github.com/altic-dev/DynamicNotchKit)
- **History, stats, and custom dictionary** persistence, file-based (no external database)
- **AI post-processing** — punctuation, capitalization, and provider-based (Apple Intelligence / OpenAI / Groq / custom) dictation cleanup

## Integration

The host app owns zero AiVoiceKit-specific UI logic beyond wiring two callbacks:

```swift
let voiceEngine = VoiceEngineMacOS(
    onCommandReceived: { text in
        await MyApp.shared.handleVoiceCommand(text)
    },
    onEditRequested: { selectedText, instruction in
        return await MyApp.shared.rewrite(selectedText, instruction: instruction)
    }
)
```

`VoiceEngine` is a plain `AnyObject, ObservableObject` protocol — no host framework types appear in the package's public API.

## Package layout

```
Sources/
  AiVoiceKit/
    Public/     — protocols, types, enums (VoiceEngine, ASRModel, VoiceSettings)
    macOS/      — CoreAudio, NSEvent, Accessibility, overlay (macOS only)
    Shared/     — ASR catalog, history, stats, settings persistence (cross-platform)
  CoreAudioCaptureSupport/ — C target for low-level CoreAudio capture
Tests/
  AiVoiceKitTests/
```

## Requirements

- macOS 15+ (primary target). iOS 18+/visionOS 2+ platforms are declared but currently compile no macOS-only code paths in — full support is planned but not yet implemented.
- Swift 6.0 toolchain
- Microphone access; Accessibility permission for global hotkeys and typed output

## License

AiVoiceKit is a derivative work of [FluidVoice](https://github.com/altic-dev/FluidVoice) (GPLv3, © altic-dev contributors) and is distributed under the same license — see [LICENSE](./LICENSE).

Third-party dependencies and their licenses are listed in-app via the Open Source Licenses sheet, and include:

| Dependency | License | Purpose |
|---|---|---|
| [FluidAudio](https://github.com/altic-dev/FluidAudio) | MIT | Parakeet/Nemotron/Cohere CoreML ASR |
| [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) | MIT | Whisper inference |
| [DynamicNotchKit](https://github.com/altic-dev/DynamicNotchKit) | MIT | Notch overlay window management |
| [PromiseKit](https://github.com/mxcl/PromiseKit) | MIT | Legacy async utilities (updater path) |
