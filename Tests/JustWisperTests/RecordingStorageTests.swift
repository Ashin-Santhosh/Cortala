import Foundation
import Testing
@testable import JustWisper

struct RecordingStorageTests {
    @Test func meetingSelectionPersistsAndDoesNotMoveExistingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = RecordingStorage(root: root)
        let old = try storage.destination(isMeeting: true, extension: "wav")
        try Data("old recording".utf8).write(to: old)
        try storage.selectMeetingDirectory(folder)
        let meeting = try storage.destination(isMeeting: true, extension: "m4a")
        let dictation = try storage.destination(isMeeting: false, extension: "wav")
        #expect(meeting.deletingLastPathComponent().path == folder.path)
        #expect(dictation.deletingLastPathComponent() == storage.defaultDirectory)
        #expect(FileManager.default.fileExists(atPath: old.path))
        let reloaded = RecordingStorage(root: root)
        #expect(reloaded.meetingDirectory.path == folder.path)
        #expect(reloaded.isManaged(meeting))
        #expect(!reloaded.isManaged(folder.appendingPathComponent("unrelated.m4a")))
        try reloaded.selectMeetingDirectory(nil)
        #expect(reloaded.isManaged(meeting))
    }
    @Test func unavailableFolderFallsBackWithoutLosingAudioOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("RemovedVolume")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = RecordingStorage(root: root)
        try storage.selectMeetingDirectory(folder)
        try FileManager.default.removeItem(at: folder)
        let destination = try storage.destination(isMeeting: true, extension: "wav")
        #expect(destination.deletingLastPathComponent() == storage.defaultDirectory)
        #expect(storage.warning != nil)
        #expect(storage.meetingDirectory.path == folder.path)
        #expect(storage.isManaged(destination))
    }
    @Test func corruptedPreferencesArePreservedAndAudioStillHasSafeDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let preferences = root.appendingPathComponent("recording-storage.json")
        let original = Data("unreadable original".utf8)
        try original.write(to: preferences)
        let storage = RecordingStorage(root: root)
        let destination = try storage.destination(isMeeting: true, extension: "wav")
        #expect(storage.isManaged(destination))
        #expect(storage.warning != nil)
        #expect(try Data(contentsOf: preferences) == original)
    }
    @Test @MainActor func failedMeetingTranscriptionStagesAudioInChosenFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Chosen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        try store.recordingStorage.selectMeetingDirectory(folder)
        store.library.settings.localExecutable = "/nonexistent/whisper"
        store.library.settings.speechProvider = "local"
        let audio = root.appendingPathComponent("capture.wav")
        let bytes = Data("original meeting bytes".utf8)
        try bytes.write(to: audio)
        store.process(audio, isMeeting: true, owned: true)
        for _ in 0..<200 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        let entry = try #require(store.library.history.first)
        let saved = URL(fileURLWithPath: try #require(entry.audioPath))
        #expect(saved.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(try Data(contentsOf: saved) == bytes)
        store.deleteTranscript(entry)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }
}
