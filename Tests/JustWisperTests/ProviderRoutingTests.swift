import Foundation
import Testing
@testable import JustWisper

struct ProviderRoutingTests {
    @Test func independentRoutesLoadOnlyTheirOwnKeysAndHonorModelOverrides() throws {
        let speech = ProviderConnection(name: "Speech", kind: "speech", endpoint: "https://speech.example/v1/audio/transcriptions", model: "speech-model")
        let rewrite = ProviderConnection(name: "Text", endpoint: "https://text.example/v1/chat/completions", model: "text-model")
        var mode = DictationMode(name: "Custom")
        mode.speechConnectionID = speech.id; mode.rewriteConnectionID = rewrite.id; mode.rewriteModelOverride = "text-override"
        var requested: [String] = []
        let route = try ModeProviderRouting.resolve(mode: mode, settings: AppSettings(), connections: [speech, rewrite], defaultSpeechKey: "global-speech", defaultRewriteKey: "global-text") { account in requested.append(account); return account == speech.keychainAccount ? "speech-own" : "text-own" }
        #expect(route.speechKey == "speech-own")
        #expect(route.rewriteKey == "text-own")
        #expect(route.settings.speechEndpoint == speech.endpoint)
        #expect(route.settings.rewriteEndpoint == rewrite.endpoint)
        #expect(route.settings.rewriteModel == "text-override")
        #expect(Set(requested) == Set([speech.keychainAccount, rewrite.keychainAccount]))
    }
    @Test func emptyConnectionKeyNeverFallsBackToGlobalAndHostChangesIdentity() throws {
        let connection = ProviderConnection(name: "Local", endpoint: "http://localhost:11434/v1/chat/completions", model: "qwen3:8b")
        var mode = DictationMode(name: "Custom"); mode.rewriteConnectionID = connection.id
        let route = try ModeProviderRouting.resolve(mode: mode, settings: AppSettings(), connections: [connection], defaultSpeechKey: "", defaultRewriteKey: "private-global") { _ in "" }
        #expect(route.rewriteKey.isEmpty)
        var moved = connection; moved.endpoint = "https://other.example/v1/chat/completions"
        #expect(moved.keychainAccount != connection.keychainAccount)
        var renamed = connection; renamed.name = "Renamed"
        #expect(renamed.keychainAccount == connection.keychainAccount)
    }
    @Test func credentialOriginsNormalizeDefaultsButSeparateServersAndConnections() {
        let a = ProviderConnection(name: "A", endpoint: "https://EXAMPLE.com/v1/messages", model: "m")
        var same = a; same.endpoint = "https://example.com:443/other/path"
        #expect(a.keychainAccount == same.keychainAccount)
        var differentPort = a; differentPort.endpoint = "https://example.com:8443/v1/messages"
        #expect(a.keychainAccount != differentPort.keychainAccount)
        let b = ProviderConnection(name: "B", endpoint: a.endpoint, model: "m")
        #expect(a.keychainAccount != b.keychainAccount)
        #expect(ProviderCredentialIdentity.defaultAccount(kind: "rewrite", endpoint: a.endpoint) != ProviderCredentialIdentity.defaultAccount(kind: "speech", endpoint: a.endpoint))
    }
    @Test func configurationExportsConnectionIdentityWithoutCredentialMaterial() throws {
        var state = LibraryState()
        state.connections = [ProviderConnection(name: "Private provider", endpoint: "https://example.com/v1/messages", model: "m")]
        state.modes[0].rewriteConnectionID = state.connections[0].id
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(LibraryState.self, from: data)
        #expect(decoded.connections == state.connections)
        #expect(decoded.modes[0].rewriteConnectionID == state.connections[0].id)
        #expect(!String(decoding: data, as: UTF8.self).contains("keychainAccount"))
        #expect(!String(decoding: data, as: UTF8.self).contains("apiKey"))
    }
    @Test func missingConnectionFailsRatherThanUsingAnotherProvider() {
        var mode = DictationMode(name: "Custom"); mode.speechConnectionID = UUID()
        #expect(throws: (any Error).self) { try ModeProviderRouting.resolve(mode: mode, settings: AppSettings(), connections: [], defaultSpeechKey: "global", defaultRewriteKey: "global") { _ in "" } }
    }
}

struct CorrectionLearningTests {
    @Test func explicitNameAndNumberEditsProduceSeparateReviewableSuggestions() {
        let suggestions = CorrectionLearning.suggestions(original: "Meet Jon at 14 tomorrow.", edited: "Meet John at 16 tomorrow.", recognized: "meet jon at 14 tomorrow")
        #expect(suggestions.map(\.phrase) == ["Jon", "14"])
        #expect(suggestions.map(\.replacement) == ["John", "16"])
    }
    @Test func punctuationInsertionsAndUnrecognizedFormattingDoNotCreateGuesses() {
        #expect(CorrectionLearning.suggestions(original: "hello world", edited: "hello, world!", recognized: "hello world").isEmpty)
        #expect(CorrectionLearning.suggestions(original: "hello world", edited: "hello wonderful world", recognized: "hello world").isEmpty)
        #expect(CorrectionLearning.suggestions(original: "Formatted heading", edited: "Different heading", recognized: "raw speech").isEmpty)
    }
    @Test @MainActor func libraryAndSnapshotsHavePrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        #expect(store.save())
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("library.json").path)
        #expect((rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test @MainActor func unreviewedArbitraryCorrectionsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        let entry = Transcript(title: "Hello", raw: "hello world", text: "Hello world.", mode: "Clean", duration: 2)
        store.library.history = [entry]
        #expect(!store.saveTranscriptEdits(entry, text: "Hello world!", corrections: [CorrectionSuggestion(phrase: "password", replacement: "invented")]))
        #expect(store.library.vocabulary.isEmpty)
        #expect(store.library.history[0].text == entry.text)
    }
    @Test @MainActor func editsAndConfirmedCorrectionsPersistWithoutReplacingRaw() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        let entry = Transcript(title: "Meet Jon", raw: "meet jon tomorrow", text: "Meet Jon tomorrow.", mode: "Clean", duration: 2)
        store.library.history = [entry]
        #expect(store.saveTranscriptEdits(entry, text: "Meet John tomorrow.", corrections: [CorrectionSuggestion(phrase: "Jon", replacement: "John")]))
        let saved = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
        #expect(saved.history[0].raw == entry.raw)
        #expect(saved.history[0].text == "Meet John tomorrow.")
        #expect(saved.vocabulary[0].replacement == "John")
    }
}
