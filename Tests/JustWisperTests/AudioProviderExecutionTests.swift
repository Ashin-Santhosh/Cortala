import Foundation
import AVFoundation
import Testing
@testable import JustWisper

struct AudioProviderExecutionTests {
    @Test func localProcessProtocolPreservesRequestedLanguageAndVocabulary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-whisper")
        let script = #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -of) shift; output="$1" ;;
            -l) shift; [ "$1" = "de" ] || exit 4 ;;
            --prompt) shift; [ "$1" = "Projekt" ] || exit 5 ;;
          esac
          shift
        done
        printf '%s' '{"transcription":[{"offsets":{"from":0,"to":1000},"text":" Hallo Projekt"}]}' > "$output.json"
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = directory.appendingPathComponent("fixture-model")
        try Data([1]).write(to: model)
        let audio = directory.appendingPathComponent("audio.wav")
        try writeSilence(to: audio)
        let result = try await TranscriptionService.transcribeDetailed(TranscriptionRequest(audioURL: audio, endpoint: nil,
            apiKey: "", model: "", language: "de", vocabulary: "Projekt", localExecutable: executable.path, localModel: model.path, provider: "local"))
        #expect(result.text == "Hallo Projekt")
        #expect(result.segments.first?.end == 1)
    }

    @Test func cancellationStopsLocalProcessAndPropagates() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-slow-whisper")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = directory.appendingPathComponent("fixture-model")
        try Data([1]).write(to: model)
        let audio = directory.appendingPathComponent("audio.wav")
        try writeSilence(to: audio)
        let task = Task {
            try await TranscriptionService.transcribeDetailed(TranscriptionRequest(audioURL: audio, endpoint: nil,
                apiKey: "", model: "", language: "auto", vocabulary: "", localExecutable: executable.path, localModel: model.path, provider: "local"))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled transcription should throw") }
        catch { #expect(error is CancellationError) }
    }

    /// Explicit opt-in: uses the installed engine/model and a public JFK sample, never the microphone.
    @Test func installedWhisperSmoke() async throws {
        guard ProcessInfo.processInfo.environment["JUSTWISPER_LOCAL_SMOKE"] == "1" else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let request = TranscriptionRequest(audioURL: URL(fileURLWithPath: "/opt/homebrew/share/whisper.cpp/jfk.wav"), endpoint: nil,
            apiKey: "", model: "", language: "en", vocabulary: "", localExecutable: "/opt/homebrew/bin/whisper-cli",
            localModel: root.appendingPathComponent("Models/ggml-medium.bin").path, provider: "local")
        let result = try await TranscriptionService.transcribeDetailed(request)
        #expect(result.text.lowercased().contains("country"))
        #expect(!result.segments.isEmpty)
        #expect(result.segments.allSatisfy { $0.start >= 0 && $0.end >= $0.start })
    }

    /// Explicit opt-in against the user's existing local Ollama server using public sample text.
    @Test func installedOllamaSmoke() async throws {
        guard ProcessInfo.processInfo.environment["JUSTWISPER_OLLAMA_SMOKE"] == "1" else { return }
        let output = try await RewriteService.rewrite(text: "hello world", instruction: "Capitalize the text and add punctuation. /no_think",
            endpoint: URL(string: "http://localhost:11434/v1/chat/completions")!, apiKey: "", model: "qwen3:8b")
        #expect(output.lowercased().contains("hello"))
        #expect(output.lowercased().contains("world"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("JustWisper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func writeSilence(to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
