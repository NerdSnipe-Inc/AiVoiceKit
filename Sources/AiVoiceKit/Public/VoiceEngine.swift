// Sources/AiVoiceKit/Public/VoiceEngine.swift
import Foundation
import Combine

public enum RecordingMode: String, Equatable, Sendable {
    case dictation, command, edit, fileTranscription
}

public enum VoiceEngineState: Equatable, Sendable {
    case idle
    case recording(mode: RecordingMode)
    case processing
    case error(String)
}

@MainActor
public protocol VoiceEngine: AnyObject, ObservableObject {
    var state: VoiceEngineState { get }
    var transcript: String { get }
    var selectedASRModel: ASRModel { get set }
    var settings: VoiceSettings { get }
    func startDictation() async throws
    func stopDictation() async -> String?
    func startCommandMode() async throws
    func stopCommandMode() async
    func startEditMode(selectedText: String) async throws
    func stopEditMode() async -> String?
}
