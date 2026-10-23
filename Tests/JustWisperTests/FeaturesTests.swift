import Foundation
import Testing
@testable import JustWisper

struct FeaturesTests {
    @Test func csvRoundTripPreservesQuotedUnicodeAndMultilineFields() throws {
        let entries = [VocabularyEntry(phrase: "Müller, Inc.", replacement: "A \"quoted\"\r\ncompany"), VocabularyEntry(phrase: "മലയാളം", replacement: "")]
        let decoded = try VocabularyCSV.decode(VocabularyCSV.encode(entries))
        #expect(decoded.map(\.phrase) == entries.map(\.phrase))
        #expect(decoded.map(\.replacement) == entries.map(\.replacement))
    }
    @Test func csvAcceptsBomHeaderAndSingleColumn() throws {
        let entries = try VocabularyCSV.decode("\u{FEFF}phrase,replacement\r\nAlice\r\n\"Bob\",\"Robert\"\r\n")
        #expect(entries.count == 2)
        #expect(entries[0].replacement.isEmpty)
        #expect(entries[1].replacement == "Robert")
    }
    @Test func csvRejectsMalformedRowsWithoutPartialImport() {
        for input in ["\"unfinished", "a,\"b\"oops", "a,b,c", ",replacement", "a\"quote,b"] {
            #expect(throws: (any Error).self) { try VocabularyCSV.decode(input) }
        }
    }
    @Test func snippetExpandsWholeTriggerWithoutCascading() {
        let snippets = [TextSnippet(trigger: "my signature", text: "Best,\nAlice"), TextSnippet(trigger: "Alice", text: "Other")]
        #expect(SnippetExpansion.expand("Insert MY SIGNATURE. Alice.", snippets: snippets) == "Insert Best,\nAlice. Other.")
    }
    @Test func statisticsExcludePendingAndRespectDateRange() {
        let now = Date(), yesterday = now.addingTimeInterval(-86400)
        var old = Transcript(title: "Old", raw: "hello", text: "two words", mode: "Dictation", duration: 60); old.date = yesterday
        var recent = Transcript(title: "New", raw: "hi", text: "three short words", mode: "Dictation", duration: 30); recent.date = now
        let pending = Transcript(title: "Pending", raw: "", text: "", mode: "Dictation", duration: 100)
        let stats = HistoryStatistics(entries: [old, recent, pending], since: now.addingTimeInterval(-3600))
        #expect(stats.recordings == 1)
        #expect(stats.words == 3)
        #expect(stats.audioSeconds == 30)
        #expect(stats.wordsPerMinute == 6)
    }
}

@MainActor
struct ConfigurationSyncTests {
    @Test func snapshotExcludesHistoryAndPreservesChangedRemoteFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = ConfigurationSyncService()
        #expect(try service.inspect(folder: folder) == nil)
        var local = LibraryState()
        local.history = [Transcript(title: "Private", raw: "Private", text: "Private", mode: "Dictation", duration: 3)]
        local.settings.configSyncFolder = folder.path
        switch try service.push(local, folder: folder) { case .saved: break; case .conflict: Issue.record("First push should succeed") }
        let pulled = try service.pull(folder: folder)
        #expect(pulled.history.isEmpty)
        #expect(pulled.settings.configSyncFolder.isEmpty)
        let remoteURL = folder.appendingPathComponent("JustWisper-configuration.json")
        let replacement = Data("external change".utf8)
        try replacement.write(to: remoteURL, options: .atomic)
        switch try service.push(local, folder: folder) {
        case .saved: Issue.record("A changed remote must not be overwritten")
        case .conflict(let copy): #expect(FileManager.default.fileExists(atPath: copy.path))
        }
        #expect(try Data(contentsOf: remoteURL) == replacement)
    }
}

struct ModeOverrideTests {
    @Test func overridesChangeModelsWithoutChangingEndpointsOrCredentialRoutes() {
        var settings = AppSettings()
        settings.speechModel = "base-speech"; settings.rewriteModel = "base-text"
        var mode = DictationMode(name: "Custom")
        mode.speechModelOverride = "other-speech"; mode.rewriteModelOverride = "other-text"; mode.localModelOverride = "/models/other.bin"
        let resolved = settings.resolving(mode: mode)
        #expect(resolved.speechModel == "other-speech")
        #expect(resolved.rewriteModel == "other-text")
        #expect(resolved.localModel == "/models/other.bin")
        #expect(resolved.speechEndpoint == settings.speechEndpoint)
        #expect(resolved.rewriteEndpoint == settings.rewriteEndpoint)
        #expect(resolved.speechProvider == settings.speechProvider)
        #expect(settings.speechModel == "base-speech")
    }
}
