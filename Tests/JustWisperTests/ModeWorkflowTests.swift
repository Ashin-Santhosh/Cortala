import Foundation
import Testing
@testable import JustWisper

struct ModeWorkflowTests {
    @Test func toneIsAnExplicitGroundedSuffixAndRawModesStayRaw() throws {
        var message = DictationMode(name: "Message", instruction: "Format as a message.", tone: 0)
        #expect(message.processingInstruction.hasPrefix(message.instruction + "\n\nUser-selected tone:"))
        #expect(message.processingInstruction.contains("very casual and conversational"))
        #expect(message.processingInstruction.contains("Do not invent details"))
        message.tone = 1
        #expect(message.processingInstruction.contains("very formal and professional"))
        let raw = DictationMode(name: "Raw", instruction: "", tone: 1)
        #expect(raw.processingInstruction.isEmpty)
        message.tone = nil
        #expect(message.processingInstruction == message.instruction)
        let roundTrip = try JSONDecoder().decode(DictationMode.self, from: JSONEncoder().encode(message))
        #expect(roundTrip.tone == nil)
    }
    @Test func URLModeSelectionResolvesUUIDOrExactUnambiguousCaseInsensitiveName() throws {
        let email = DictationMode(name: "Email"), notes = DictationMode(name: "Meeting notes")
        #expect(try JustWisperURLCommand.parse(URL(string: "justwisper://mode?id=\(email.id.uuidString.lowercased())")!, modes: [email, notes]) == .selectMode(email.id))
        #expect(try JustWisperURLCommand.parse(URL(string: "justwisper://mode?name=eMaIL")!, modes: [email, notes]) == .selectMode(email.id))
        #expect(try JustWisperURLCommand.parse(URL(string: "justwisper://start?mode=Meeting%20notes")!, modes: [email, notes]) == .start(notes.id))
        #expect(try JustWisperURLCommand.parse(URL(string: "justwisper://record")!, modes: [email]) == .toggle(nil))
    }
    @Test func URLModeSelectionRejectsUnknownAmbiguousOrInjectedParameters() {
        let modes = [DictationMode(name: "Email"), DictationMode(name: "EMAIL")]
        for url in ["justwisper://mode?name=Email", "justwisper://mode?name=Ema", "justwisper://mode?id=missing", "justwisper://mode?name=Email&name=EMAIL", "justwisper://start?endpoint=https://other.example", "justwisper://stop?name=Email", "justwisper://mode/Email", "justwisper://mode?name=Email#cancel"] {
            #expect(throws: (any Error).self) { try JustWisperURLCommand.parse(URL(string: url)!, modes: modes) }
        }
    }
    @Test @MainActor func selectedModeURLPersistsWithoutRecordingOrPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        let email = try #require(store.library.modes.first { $0.name == "Email" })
        store.executeCommandURL(URL(string: "justwisper://mode?id=\(email.id.uuidString)")!)
        #expect(store.pendingExternalCommand == .selectMode(email.id))
        #expect(store.selectedMode.id != email.id)
        store.approveExternalCommand()
        #expect(store.selectedMode.id == email.id)
        #expect(!store.busy)
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        #expect(saved.selectedModeID == email.id)
    }
    @Test @MainActor func indefiniteRetentionSurvivesCodingAndDoesNotPrune() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let recording = recordings.appendingPathComponent("old.wav")
        try Data([1]).write(to: recording)
        store.library.settings.retentionDays = 0
        store.library.settings.retainAudio = true
        let entry = Transcript(date: Date(timeIntervalSince1970: 0), title: "Old", raw: "Recognized", text: "Recognized", mode: "Dictation", duration: 1, audioPath: recording.path)
        store.library.history = [entry]
        store.pruneRetainedAudio()
        #expect(store.library.history[0].audioPath == recording.path)
        #expect(FileManager.default.fileExists(atPath: recording.path))
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(store.library.settings))
        #expect(settings.retentionDays == 0)
    }
    @Test @MainActor func automaticSyncPublishesSavedChangesAndKeepsDraftsLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root.appendingPathComponent("library"), startDesktop: false, loadCredentials: false)
        store.library.settings.configSyncFolder = shared.path
        store.startConfigurationSync(.useLocal)
        defer { store.stopConfigurationSync() }
        #expect(store.library.settings.autoSyncConfiguration)
        store.library.vocabulary.append(VocabularyEntry(phrase: "Unsaved draft"))
        store.configSync.pollAutomatic()
        let file = shared.appendingPathComponent("JustWisper-configuration.json")
        let before = try JSONDecoder().decode(ConfigurationSyncService.Snapshot.self, from: Data(contentsOf: file))
        #expect(before.configuration.vocabulary.isEmpty)
        #expect(store.save())
        store.configSync.pollAutomatic()
        let after = try JSONDecoder().decode(ConfigurationSyncService.Snapshot.self, from: Data(contentsOf: file))
        #expect(after.configuration.vocabulary.first?.phrase == "Unsaved draft")
    }

    @Test func desktopControlMigrationKeepsDisabledChoicesAndPrivacyDefaults() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{\"showOverlay\":false}".utf8))
        #expect(old.effectiveRecordingOverlayStyle == .none)
        #expect(old.mouseRecordingButton == nil)
        #expect(!old.captureRecentClipboard)
        #expect(old.modeSwitcherShortcut == nil)
        var settings = AppSettings()
        settings.recordingOverlayStyle = .mini
        settings.modeSwitcherShortcut = nil
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(saved.effectiveRecordingOverlayStyle == .mini)
        #expect(saved.modeSwitcherShortcut == nil)
        #expect(saved.mouseRecordingButton == nil)
        #expect(!saved.captureRecentClipboard)
    }

}
