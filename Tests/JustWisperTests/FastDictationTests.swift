import Foundation
import Testing
@testable import JustWisper

struct FastDictationTests {
    @Test func incompleteStreamingCanRecoverLocallyWithoutCloudUpload() {
        var settings = AppSettings()
        var mode = DictationMode(name: "Dictation", instruction: "")
        settings.speechProvider = "local"
        #expect(FastDictationRecovery.canUseSelectedLocalModel(settings: settings, mode: mode))
        settings.speechProvider = "cloud"
        #expect(!FastDictationRecovery.canUseSelectedLocalModel(settings: settings, mode: mode))
        settings.speechProvider = "local"
        mode.speechConnectionID = UUID()
        #expect(!FastDictationRecovery.canUseSelectedLocalModel(settings: settings, mode: mode))
    }
    @Test func fastEngineChoiceIsExplicitAndBackwardCompatible() throws {
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(!legacy.fastOnDeviceDictation)
        var settings = AppSettings()
        settings.fastOnDeviceDictation = true
        settings.liveCaptions = false
        settings.liveCaptionEngine = "provider"
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.fastOnDeviceDictation)
        #expect(!restored.liveCaptions)
        #expect(restored.liveCaptionEngine == "provider")
    }

    @Test @MainActor func stableOnDeviceRawTextSkipsWhisperAndLanguageProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        store.library.settings.localExecutable = "/no-such-whisper-cli"
        store.library.settings.rewriteEndpoint = "not-an-endpoint"
        store.library.settings.rewriteModel = "unavailable-model"
        store.library.settings.autoPaste = false
        store.library.settings.showOverlay = false
        #expect(store.save())
        var rawMode = DictationMode(name: "Raw", instruction: "")
        rawMode.speechConnectionID = UUID()
        rawMode.rewriteConnectionID = UUID()
        let audio = root.appendingPathComponent("capture.wav")
        try Data("owned capture bytes".utf8).write(to: audio)
        store.process(audio, mode: rawMode, owned: true, stableRaw: "A genuine stable on-device result.")
        for _ in 0..<200 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!store.isProcessing)
        #expect(store.error == nil)
        #expect(store.latestText == "A genuine stable on-device result.")
        #expect(store.library.history.count == 1)
        #expect(store.library.history.first?.raw == store.latestText)
        #expect(store.library.history.first?.audioPath == nil)
    }

    @Test @MainActor func formattingFailureKeepsStableRawTextAndRecoveryAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        store.library.settings.autoPaste = false
        store.library.settings.showOverlay = false
        #expect(store.save())
        var mode = DictationMode(name: "Cleanup", instruction: "Clean up punctuation.")
        mode.speechConnectionID = UUID()
        mode.rewriteConnectionID = UUID()
        let audio = root.appendingPathComponent("capture.wav")
        let bytes = Data("recoverable on-device recording".utf8)
        try bytes.write(to: audio)
        store.process(audio, mode: mode, owned: true, stableRaw: "Stable original text")
        for _ in 0..<200 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!store.isProcessing)
        #expect(store.error?.contains("language connection") == true)
        let entry = try #require(store.library.history.first)
        #expect(entry.raw == "Stable original text")
        #expect(entry.text == "Stable original text")
        let path = try #require(entry.audioPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        #expect(saved.history.first?.raw == "Stable original text")
    }
}
