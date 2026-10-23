import Foundation
import AVFoundation
import Testing
@testable import JustWisper

struct NoSpeechTests {
    @Test func noSpeechIsNotConfusedWithPermissionOrServiceErrors() {
        #expect(NoSpeechPolicy.isAppleNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        #expect(!NoSpeechPolicy.isAppleNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 1700)))
        #expect(!NoSpeechPolicy.isAppleNoSpeech(NSError(domain: "kAFAssistantErrorDomain", code: 1107)))
        #expect(!NoSpeechPolicy.isAppleNoSpeech(NSError(domain: "other", code: 1110)))
        #expect(NoSpeechPolicy.isEmptyTranscript(" \n[BLANK_AUDIO] \n"))
        #expect(NoSpeechPolicy.isEmptyTranscript(""))
        #expect(!NoSpeechPolicy.isEmptyTranscript("Please say silence."))
        #expect(!NoSpeechPolicy.isEmptyTranscript("Say [BLANK_AUDIO] out loud."))
    }
    private func wav(at url: URL, amplitude: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channels = try #require(buffer.floatChannelData)
        for i in 0..<16_000 { channels[0][i] = amplitude * sin(Float(i) * 0.1) }
        let output = try AVAudioFile(forWriting: url, settings: format.settings)
        try output.write(from: buffer)
    }
    @Test func quietAudioIsNotMistakenForDigitalSilence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let silent = root.appendingPathComponent("silent.wav"), quiet = root.appendingPathComponent("quiet.wav")
        try wav(at: silent, amplitude: 0)
        try wav(at: quiet, amplitude: 0.001)
        #expect(await NoSpeechPolicy.isDigitalSilence(silent))
        #expect(await !NoSpeechPolicy.isDigitalSilence(quiet))
        #expect(await !NoSpeechPolicy.isDigitalSilence(root.appendingPathComponent("missing.wav")))
    }
    @Test @MainActor func silentCaptureDoesNothingWithoutCallingInvalidProviders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        store.latestText = "Existing transcript"
        store.library.settings.localExecutable = "/invalid/engine"
        store.library.settings.rewriteEndpoint = "invalid"
        let audio = root.appendingPathComponent("silent.wav")
        try wav(at: audio, amplitude: 0)
        store.process(audio, owned: true)
        for _ in 0..<200 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(!store.isProcessing)
        #expect(store.error == nil)
        #expect(store.status == "Ready when you are")
        #expect(store.latestText == "Existing transcript")
        #expect(store.library.history.isEmpty)
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        #expect(saved.history.isEmpty)
    }
    @Test @MainActor func emptyOrBlankMarkerResultLeavesNoHistoryEntry() async throws {
        for text in ["", "[BLANK_AUDIO]"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
            let audio = root.appendingPathComponent("capture.wav")
            try Data("fixture".utf8).write(to: audio)
            store.process(audio, owned: true, stableRaw: text)
            for _ in 0..<200 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(store.error == nil)
            #expect(store.library.history.isEmpty)
            #expect(store.latestText.isEmpty)
        }
    }
}
