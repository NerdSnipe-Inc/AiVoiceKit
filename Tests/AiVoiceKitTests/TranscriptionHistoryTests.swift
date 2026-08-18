// Tests/AiVoiceKitTests/TranscriptionHistoryTests.swift
import XCTest
@testable import AiVoiceKit

final class TranscriptionHistoryTests: XCTestCase {
    func testAppendAndRetrieve() {
        let store = TranscriptionHistoryStore(storageURL: temporaryURL())
        let entry = TranscriptionEntry(
            id: UUID(), text: "Hello world", model: .appleSpeech,
            timestamp: Date(), audioDurationSeconds: nil
        )
        store.append(entry)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "Hello world")
    }

    func testDeleteEntry() {
        let store = TranscriptionHistoryStore(storageURL: temporaryURL())
        let entry = TranscriptionEntry(id: UUID(), text: "test", model: .appleSpeech, timestamp: Date(), audioDurationSeconds: nil)
        store.append(entry)
        store.delete(id: entry.id)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testEntriesNewestFirst() {
        let store = TranscriptionHistoryStore(storageURL: temporaryURL())
        let first = TranscriptionEntry(text: "first", model: .appleSpeech)
        let second = TranscriptionEntry(text: "second", model: .appleSpeech)
        store.append(first)
        store.append(second)
        XCTAssertEqual(store.entries[0].text, "second")
        XCTAssertEqual(store.entries[1].text, "first")
    }

    func testDeleteAllClearsEntries() {
        let store = TranscriptionHistoryStore(storageURL: temporaryURL())
        store.append(TranscriptionEntry(text: "a", model: .appleSpeech))
        store.append(TranscriptionEntry(text: "b", model: .appleSpeech))
        store.deleteAll()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSearchFindsMatches() {
        let store = TranscriptionHistoryStore(storageURL: temporaryURL())
        store.append(TranscriptionEntry(text: "Hello world", model: .appleSpeech))
        store.append(TranscriptionEntry(text: "Goodbye moon", model: .appleSpeech))
        let results = store.search(query: "hello")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].text, "Hello world")
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
    }
}
