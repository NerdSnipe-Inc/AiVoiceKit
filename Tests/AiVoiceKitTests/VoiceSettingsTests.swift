// Tests/AiVoiceKitTests/VoiceSettingsTests.swift
import XCTest
@testable import AiVoiceKit

final class VoiceSettingsTests: XCTestCase {
    func testDefaultSelectedModelIsAppleSpeech() {
        XCTAssertEqual(VoiceSettings().selectedASRModel, .appleSpeech)
    }
    func testRoundTripCodable() throws {
        var settings = VoiceSettings()
        settings.selectedASRModel = .parakeetV3
        settings.copyToClipboard = true
        settings.audioHistoryBudgetGB = 5.0
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(VoiceSettings.self, from: data)
        XCTAssertEqual(settings, decoded)
    }
}
