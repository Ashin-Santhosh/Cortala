import Foundation
import Testing
@testable import JustWisper

struct AppStoreDraftPrivacyTests {
    @Test @MainActor func recordingRecoveryDeletionAndModeChoicePreserveUnsavedConfigurationDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root.appendingPathComponent("library"), startDesktop: false, loadCredentials: false)
        store.library.settings.localExecutable = "/no-such-whisper-cli"
        store.library.settings.showOverlay = false
        store.library.settings.configSyncFolder = shared.path
        store.startConfigurationSync(.useLocal)
        defer { store.stopConfigurationSync() }
        let draft = VocabularyEntry(phrase: "Private unsaved draft")
        store.library.vocabulary.append(draft)
        let source = root.appendingPathComponent("capture.wav")
        try Data("recoverable recording".utf8).write(to: source)
        store.process(source, owned: true)
        for _ in 0..<200 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!store.isProcessing)
        let recovery = try #require(store.library.history.first)
        #expect(recovery.audioPath != nil)
        let stateURL = root.appendingPathComponent("library/library.json")
        let afterRecovery = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: stateURL))
        #expect(afterRecovery.history.first?.id == recovery.id)
        #expect(afterRecovery.vocabulary.isEmpty)
        #expect(store.library.vocabulary.first?.id == draft.id)
        let mode = try #require(store.library.modes.last)
        #expect(store.chooseMode(mode.id))
        store.deleteTranscript(recovery)
        store.configSync.pollAutomatic()
        let snapshotURL = shared.appendingPathComponent("JustWisper-configuration.json")
        let beforeSave = try JSONDecoder().decode(ConfigurationSyncService.Snapshot.self, from: Data(contentsOf: snapshotURL))
        #expect(beforeSave.configuration.vocabulary.isEmpty)
        #expect(beforeSave.configuration.selectedModeID == mode.id)
        let afterDelete = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: stateURL))
        #expect(afterDelete.history.isEmpty)
        #expect(afterDelete.vocabulary.isEmpty)
        #expect(store.library.vocabulary.first?.id == draft.id)
        #expect(store.save())
        store.configSync.pollAutomatic()
        let afterSave = try JSONDecoder().decode(ConfigurationSyncService.Snapshot.self, from: Data(contentsOf: snapshotURL))
        #expect(afterSave.configuration.vocabulary.first?.id == draft.id)
    }

    @Test @MainActor func terminationPreservesQueuedCaptureWithoutCommittingDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        store.library.settings.showOverlay = false
        #expect(store.save())
        store.library.vocabulary.append(VocabularyEntry(phrase: "Unsaved draft"))
        let source = root.appendingPathComponent("capture.wav")
        let bytes = Data("recording to recover after quit".utf8)
        try bytes.write(to: source)
        // Terminate before the scheduled recognition task gets a turn to stage it.
        store.process(source, owned: true)
        await store.prepareForTermination()
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        #expect(saved.vocabulary.isEmpty)
        let pending = try #require(saved.history.first)
        #expect(pending.raw.isEmpty)
        let path = try #require(pending.audioPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }
}
