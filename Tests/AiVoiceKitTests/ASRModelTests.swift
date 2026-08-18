// Tests/AiVoiceKitTests/ASRModelTests.swift
import XCTest
@testable import AiVoiceKit

final class ASRModelTests: XCTestCase {
    func testAppleSpeechRequiresNoAppleSilicon() {
        XCTAssertFalse(ASRModel.appleSpeech.requiresAppleSilicon)
    }
    func testParakeetRequiresAppleSilicon() {
        XCTAssertTrue(ASRModel.parakeetFlash.requiresAppleSilicon)
        XCTAssertTrue(ASRModel.parakeetV3.requiresAppleSilicon)
    }
    func testCatalogContainsAllCases() {
        let catalogIDs = Set(ASRModelDescriptor.catalog.map(\.model))
        for model in ASRModel.allCases {
            XCTAssertTrue(catalogIDs.contains(model), "Missing descriptor for \(model)")
        }
    }
    func testAppleSpeechHasZeroDownloadSize() {
        let desc = ASRModelDescriptor.catalog.first { $0.model == .appleSpeech }!
        XCTAssertEqual(desc.downloadSizeMB, 0)
    }
}
