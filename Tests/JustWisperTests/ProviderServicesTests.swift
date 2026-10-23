import Foundation
import Testing
@testable import JustWisper

struct ProviderServicesTests {
    @Test func endpointRejectsRemotePlaintextAndEmbeddedCredentials() throws {
        for endpoint in ["http://example.com/v1/audio/transcriptions", "https://secret@example.com/v1", "file:///tmp/audio"] {
            #expect(throws: (any Error).self) { try ProviderHTTP.validate(URL(string: endpoint)!) }
        }
        for endpoint in ["https://api.example.com/v1/audio/transcriptions", "http://localhost:11434/v1/chat/completions", "http://127.0.0.1:8000/transcribe"] {
            try ProviderHTTP.validate(URL(string: endpoint)!)
        }
    }

    @Test func localProviderRejectsMissingExecutableBeforeReadingAudio() async {
        let request = TranscriptionRequest(audioURL: URL(fileURLWithPath: "/not-real.wav"), endpoint: nil,
            apiKey: "", model: "", language: "auto", vocabulary: "", localExecutable: "/not-real-whisper-cli",
            localModel: "/not-real-model", provider: "local")
        do {
            _ = try await TranscriptionService.transcribe(request)
            Issue.record("Invalid executable should be rejected")
        } catch {
            #expect(error.localizedDescription.contains("whisper-cli"))
        }
    }

    @Test func unknownProviderFailsWithoutNetworkRequest() async {
        let request = TranscriptionRequest(audioURL: URL(fileURLWithPath: "/not-real.wav"), endpoint: nil,
            apiKey: "", model: "", language: "auto", vocabulary: "", localExecutable: "",
            localModel: "", provider: "unsupported")
        do {
            _ = try await TranscriptionService.transcribe(request)
            Issue.record("Unknown provider should be rejected")
        } catch {
            #expect(error.localizedDescription == "Unknown transcription provider.")
        }
    }
}
