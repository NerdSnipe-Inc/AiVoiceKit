// Tests/AiVoiceKitTests/ModelRepositoryTests.swift
import XCTest
@testable import AiVoiceKit

final class ModelRepositoryTests: XCTestCase {
    func testDescriptorExistsForAllModels() {
        for model in ASRModel.allCases {
            let desc = ModelRepository.shared.descriptor(for: model)
            XCTAssertNotNil(desc, "Missing descriptor for \(model)")
        }
    }
    func testAppleSpeechIsAvailableWithoutDownload() {
        let repo = ModelRepository.shared
        XCTAssertTrue(repo.isAvailableWithoutDownload(.appleSpeech))
    }
    func testParakeetRequiresDownload() {
        XCTAssertFalse(ModelRepository.shared.isAvailableWithoutDownload(.parakeetV3))
    }
}
