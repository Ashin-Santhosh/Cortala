import Foundation
import Testing
@testable import JustWisper

@MainActor
struct AutomaticConfigurationSyncTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("justwisper-sync-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shared"), withIntermediateDirectories: true)
        return root
    }

    @Test func twoMachinesConvergeAcrossMultipleRevisionsAndResume() throws {
        let root = try fixture(), folder = root.appendingPathComponent("shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("machine-a"))
        let second = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("machine-b"))
        defer { first.stopAutomatic(); second.stopAutomatic() }
        var a = LibraryState(), b = LibraryState()
        b.settings.localExecutable = "/machine-b/whisper-cli"
        b.settings.captureFocusedText = true
        b.history = [Transcript(title: "Private B", raw: "private", text: "private", mode: "Dictation", duration: 1)]
        try first.startAutomatic(folder: folder, initialChoice: .useLocal, localState: { a }, applyRemote: { a = $0 }, onStatus: { _ in })
        try second.startAutomatic(folder: folder, initialChoice: .useShared, localState: { b }, applyRemote: { b = $0 }, onStatus: { _ in })
        a.vocabulary = [VocabularyEntry(phrase: "First edit")]
        first.pollAutomatic()
        a.vocabulary.append(VocabularyEntry(phrase: "Second edit"))
        first.pollAutomatic()
        second.pollAutomatic()
        #expect(b.vocabulary.map(\.phrase) == ["First edit", "Second edit"])
        #expect(b.settings.localExecutable == "/machine-b/whisper-cli")
        #expect(b.settings.captureFocusedText)
        #expect(b.history.first?.title == "Private B")
        #expect(second.automaticRunning)
        second.stopAutomatic()
        a.settings.language = "de"
        first.pollAutomatic()
        try second.startAutomatic(folder: folder, initialChoice: .resume, localState: { b }, applyRemote: { b = $0 }, onStatus: { _ in })
        #expect(b.settings.language == "de")
        b.vocabulary.append(VocabularyEntry(phrase: "Edit from B"))
        second.pollAutomatic()
        first.pollAutomatic()
        #expect(a.vocabulary.map(\.phrase) == b.vocabulary.map(\.phrase))
    }

    @Test func simultaneousChangesPauseAndPreserveBothSides() throws {
        let root = try fixture(), folder = root.appendingPathComponent("shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("a"))
        let second = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("b"))
        defer { first.stopAutomatic(); second.stopAutomatic() }
        var a = LibraryState(), b = LibraryState(), messages = [String]()
        try first.startAutomatic(folder: folder, initialChoice: .useLocal, localState: { a }, applyRemote: { a = $0 }, onStatus: { _ in })
        try second.startAutomatic(folder: folder, initialChoice: .useShared, localState: { b }, applyRemote: { b = $0 }, onStatus: { messages.append($0) })
        a.settings.language = "fr"
        b.settings.language = "de"
        first.pollAutomatic()
        let remote = try Data(contentsOf: folder.appendingPathComponent("JustWisper-configuration.json"))
        second.pollAutomatic()
        #expect(!second.automaticRunning)
        #expect(b.settings.language == "de")
        #expect(try Data(contentsOf: folder.appendingPathComponent("JustWisper-configuration.json")) == remote)
        let conflicts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("JustWisper-local-conflict-") }
        #expect(conflicts.count == 1)
        let copy = try JSONDecoder().decode(ConfigurationSyncService.Snapshot.self, from: Data(contentsOf: #require(conflicts.first)))
        #expect(copy.configuration.settings.language == "de")
        #expect(messages.last?.contains("both configurations changed") == true)
    }

    @Test func remoteApplyWaitsWhileBusyThenConverges() throws {
        let root = try fixture(), folder = root.appendingPathComponent("shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("a"))
        let second = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("b"))
        defer { first.stopAutomatic(); second.stopAutomatic() }
        var a = LibraryState(), b = LibraryState(), busy = false
        try first.startAutomatic(folder: folder, initialChoice: .useLocal, localState: { a }, applyRemote: { a = $0 }, onStatus: { _ in })
        try second.startAutomatic(folder: folder, initialChoice: .useShared, localState: { b }, applyRemote: {
            if busy { throw AppError.message("Recording is in progress") }
            b = $0
        }, onStatus: { _ in })
        a.settings.language = "fr"
        first.pollAutomatic()
        busy = true
        second.pollAutomatic()
        #expect(b.settings.language == "auto")
        #expect(second.automaticRunning)
        busy = false
        second.pollAutomatic()
        #expect(b.settings.language == "fr")
    }

    @Test func rollbackToOldRevisionPausesInsteadOfReplacingLocalState() throws {
        let root = try fixture(), folder = root.appendingPathComponent("shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("a"))
        let second = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("b"))
        defer { first.stopAutomatic(); second.stopAutomatic() }
        var a = LibraryState(), b = LibraryState()
        try first.startAutomatic(folder: folder, initialChoice: .useLocal, localState: { a }, applyRemote: { a = $0 }, onStatus: { _ in })
        try second.startAutomatic(folder: folder, initialChoice: .useShared, localState: { b }, applyRemote: { b = $0 }, onStatus: { _ in })
        let canonical = folder.appendingPathComponent("JustWisper-configuration.json")
        let previous = try Data(contentsOf: canonical)
        a.settings.language = "fr"
        first.pollAutomatic(); second.pollAutomatic()
        try previous.write(to: canonical, options: .atomic)
        second.pollAutomatic()
        #expect(!second.automaticRunning)
        #expect(b.settings.language == "fr")
        #expect(try Data(contentsOf: canonical) == previous)
    }

    @Test func portableSnapshotOmitsMachinePathsAndMergePreservesPrivacy() throws {
        let root = try fixture(), folder = root.appendingPathComponent("shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("state"))
        var local = LibraryState()
        local.settings.localExecutable = "/private/bin/whisper-cli"
        local.settings.localModel = "/private/models/model.bin"
        local.settings.inputDeviceUID = "Private microphone"
        local.settings.automationEnabled = true
        local.settings.autoSyncConfiguration = true
        local.settings.launchAtLogin = true
        local.settings.captureFocusedText = true
        local.settings.captureSelectedText = true
        local.settings.learnCorrections = true
        local.settings.retainAudio = true
        local.settings.retentionDays = 5
        local.settings.meetingSource = .microphone
        local.settings.enableSpeakerSeparation = true
        local.modes[0].localModelOverride = "/private/models/mode.bin"
        _ = try service.inspect(folder: folder)
        _ = try service.push(local, folder: folder)
        let shared = try service.pull(folder: folder)
        #expect(shared.settings.localExecutable.isEmpty)
        #expect(shared.settings.localModel.isEmpty)
        #expect(shared.settings.inputDeviceUID.isEmpty)
        #expect(shared.modes[0].localModelOverride.isEmpty)
        #expect(!shared.settings.captureFocusedText && !shared.settings.captureSelectedText)
        #expect(!shared.settings.automationEnabled && !shared.settings.autoSyncConfiguration && !shared.settings.retainAudio)
        #expect(!shared.settings.enableSpeakerSeparation)
        let merged = ConfigurationSyncService.mergingShared(shared, with: local)
        #expect(merged.settings.localExecutable == local.settings.localExecutable)
        #expect(merged.modes[0].localModelOverride == local.modes[0].localModelOverride)
        #expect(merged.settings.captureFocusedText && merged.settings.captureSelectedText && merged.settings.automationEnabled)
        #expect(merged.settings.autoSyncConfiguration && merged.settings.launchAtLogin && merged.settings.learnCorrections)
        #expect(merged.settings.retainAudio && merged.settings.retentionDays == 5)
        #expect(merged.settings.meetingSource == .microphone)
        #expect(merged.settings.enableSpeakerSeparation)
    }

    @Test func initialResumeNeverChoosesAWinnerAndOversizeStateIsNotPublished() throws {
        let root = try fixture(), folder = root.appendingPathComponent("shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ConfigurationSyncService(stateDirectory: root.appendingPathComponent("state"))
        let local = LibraryState()
        #expect(throws: (any Error).self) {
            try service.startAutomatic(folder: folder, initialChoice: .resume, localState: { local }, applyRemote: { _ in }, onStatus: { _ in })
        }
        #expect(!service.automaticRunning)
        var large = local
        large.modes[0].instruction = String(repeating: "a", count: 5_000_001)
        _ = try service.inspect(folder: folder)
        do {
            _ = try service.push(large, folder: folder)
            Issue.record("Oversized state must not be published")
        } catch let error as AppError {
            #expect(error.localizedDescription.contains("5 MB"))
        } catch {
            Issue.record("Expected the 5 MB configuration limit, received \(error)")
        }
        #expect(try service.inspect(folder: folder) == nil)
    }
}

struct MeetingActivityTests {
    @Test func activeMicrophoneProcessesMatchMeetingAppsWithoutBrowserFalsePositives() {
        #expect(MeetingAppDetector.activeMeetingNames(inputBundleIDs: ["us.zoom.xos", "us.zoom.xos.helper", "com.microsoft.teams2.helper", "com.google.Chrome", "us.zoom.xos-other"]) == ["Microsoft Teams", "Zoom"])
        #expect(MeetingAppDetector.activeMeetingNames(inputBundleIDs: []).isEmpty)
    }
}
