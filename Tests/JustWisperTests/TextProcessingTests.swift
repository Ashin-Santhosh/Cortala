import Foundation
import AVFoundation
import Testing
@testable import JustWisper

struct TextProcessingTests {
    @Test func vocabularyUsesWholeWordsAndLiteralReplacement() {
        let entries = [VocabularyEntry(phrase: "swift", replacement: "SwiftUI $1"), VocabularyEntry(phrase: "c++", replacement: "C plus plus")]
        #expect(TextProcessing.replaceVocabulary("SWIFT, swiftest and c++.", entries: entries) == "SwiftUI $1, swiftest and C plus plus.")
    }

    @Test func vocabularyPrefersLongestMatchWithoutCascading() {
        let entries = [VocabularyEntry(phrase: "new york", replacement: "NYC"), VocabularyEntry(phrase: "new", replacement: "fresh"), VocabularyEntry(phrase: "NYC", replacement: "Manhattan")]
        #expect(TextProcessing.replaceVocabulary("New York and NYC", entries: entries) == "NYC and Manhattan")
        #expect(TextProcessing.replaceVocabulary("über café", entries: [VocabularyEntry(phrase: "café", replacement: "coffee")]) == "über coffee")
    }

    @Test func wordErrorRateCountsInsertionsDeletionsAndSubstitutions() {
        #expect(TextProcessing.wordErrorRate(reference: "Hello, WORLD!", hypothesis: "hello world") == 0)
        #expect(TextProcessing.wordErrorRate(reference: "one two three", hypothesis: "one four") == 2.0 / 3.0)
        #expect(TextProcessing.wordErrorRate(reference: "one", hypothesis: "one two three") == 2)
        #expect(TextProcessing.wordErrorRate(reference: "", hypothesis: "") == 0)
        #expect(TextProcessing.wordErrorRate(reference: "", hypothesis: "speech") == 1)
    }

    @Test func olderSettingsReceiveNewDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"speechProvider":"cloud","language":"de","retainAudio":true}"#.utf8))
        #expect(settings.speechProvider == "cloud")
        #expect(settings.language == "de")
        #expect(settings.retainAudio)
        #expect(settings.meetingSource == .mixed)
        #expect(settings.retentionDays == 30)
    }

    @Test func localDiscoveryDoesNotReplaceAnExplicitConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Models"), withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appendingPathComponent("Models/ggml-medium.bin"))
        var settings = AppSettings()
        settings.detectLocalInstallation(resourceURL: nil, workspaceURL: directory)
        #expect(settings.localModel == directory.appendingPathComponent("Models/ggml-medium.bin").path)
        settings.localModel = "/my/model.bin"
        settings.localExecutable = "/my/whisper-cli"
        settings.detectLocalInstallation(resourceURL: nil, workspaceURL: directory)
        #expect(settings.localModel == "/my/model.bin")
        #expect(settings.localExecutable == "/my/whisper-cli")
    }

    @Test @MainActor func corruptLibraryIsPreservedBeforeSavingFreshState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("broken library {".utf8)
        try original.write(to: directory.appendingPathComponent("library.json"))
        let store = AppStore(root: directory, startDesktop: false, loadCredentials: false)
        #expect(store.error?.contains("preserved") == true)
        #expect(store.save())
        let backup = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("library-unreadable-") })
        #expect(try Data(contentsOf: backup) == original)
        #expect(try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: directory.appendingPathComponent("library.json"))).history.isEmpty)
    }

    @Test @MainActor func failedTranscriptionPreservesRecordingForRetryWithoutDuplicatingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(root: directory, startDesktop: false, loadCredentials: false)
        store.library.settings.localExecutable = "/no-such-whisper-cli"
        store.library.settings.showOverlay = false
        let source = directory.appendingPathComponent("captured.wav")
        let bytes = Data("recoverable recording".utf8)
        try bytes.write(to: source)
        store.process(source, owned: true)
        for _ in 0..<100 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!store.isProcessing)
        let entry = try #require(store.library.history.first)
        #expect(entry.raw.isEmpty)
        let path = try #require(entry.audioPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        store.reprocess(entry)
        for _ in 0..<100 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!store.isProcessing)
        #expect(store.library.history.count == 1)
        #expect(store.library.history.first?.id == entry.id)
        store.deleteTranscript(entry)
        #expect(store.library.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test @MainActor func retentionPreservesTextAndUntranscribedRecoveryAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(root: directory, startDesktop: false, loadCredentials: false)
        let recordings = directory.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        let old = recordings.appendingPathComponent("old.wav"), pending = recordings.appendingPathComponent("pending.wav")
        try Data([1]).write(to: old); try Data([2]).write(to: pending)
        let now = Date(), date = now.addingTimeInterval(-31 * 86_400)
        store.library.history = [Transcript(date: date, title: "Old", raw: "recognized", text: "recognized", mode: "Dictation", duration: 1, audioPath: old.path), Transcript(date: date, title: "Recovery", raw: "", text: "", mode: "Dictation", duration: 1, audioPath: pending.path)]
        store.pruneRetainedAudio(now: now)
        #expect(store.library.history.count == 2)
        #expect(store.library.history[0].text == "recognized")
        #expect(store.library.history[0].audioPath == nil)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: pending.path))
    }

    @Test func localConversionProducesMono16kWAV() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source.caf"), output = directory.appendingPathComponent("output.wav")
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: source, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            for channel in 0..<2 { for frame in 0..<4800 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000)) * 0.1 } }
            try file.write(from: buffer)
        } catch { throw ProviderError.message("Fixture creation failed: \(error)") }
        do { try AudioConversion.toWhisperWAV(input: source, output: output) }
        catch { throw ProviderError.message("Conversion failed: \(error)") }
        let result = try AVAudioFile(forReading: output)
        #expect(result.processingFormat.sampleRate == 16_000)
        #expect(result.processingFormat.channelCount == 1)
        #expect(abs(Int(result.length) - 1600) <= 2)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JUSTWISPER_MODEL_PATH"] != nil))
    func realLocalServiceTranscribesKnownFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let model = try #require(environment["JUSTWISPER_MODEL_PATH"])
        let sample = try #require(environment["JUSTWISPER_AUDIO_PATH"])
        let request = TranscriptionRequest(audioURL: URL(fileURLWithPath: sample), endpoint: nil, apiKey: "", model: "", language: "en", vocabulary: "", localExecutable: environment["JUSTWISPER_CLI_PATH"] ?? "/opt/homebrew/bin/whisper-cli", localModel: model, provider: "local")
        let text = try await TranscriptionService.transcribe(request)
        let reference = "And so my fellow Americans ask not what your country can do for you ask what you can do for your country"
        #expect(TextProcessing.wordErrorRate(reference: reference, hypothesis: text) < 0.25)
    }

}
