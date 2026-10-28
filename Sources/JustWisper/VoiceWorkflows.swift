import AppKit
import Foundation

struct VoiceWorkflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New workflow"
    var phrase = ""
    var enabled = false
    var alternativePhrases: [String]? = nil
    var phrases: [String] { [phrase] + (alternativePhrases ?? []) }
    var actions: [WorkflowAction] = []
}
struct WorkflowAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case openApp, openURL, webSearch, delay }
    var id = UUID()
    var kind: Kind = .openURL
    var value = ""
    var displayIndex: Int? = nil
    var fullscreen: Bool? = nil
    var browserID: String? = nil
    var browserProfile: String? = nil
    var querySeparator: String? = nil
    var summary: String {
        var result = "\(kind.title): \(value)"
        if kind == .openApp {
            if let displayIndex { result += displayIndex == 1 ? " · Main display" : " · Display \(displayIndex) (main if disconnected)" }
            if let fullscreen { result += fullscreen ? " · Fullscreen (macOS chooses Space)" : " · Windowed" }
        }
        if let browserID { result += " · \(browserID)" }
        if let browserProfile { result += " · Profile: \(browserProfile)" }
        return result
    }
}
enum WorkflowSharing {
    struct Document: Codable { var version: Int; var workflow: VoiceWorkflow }
    static func validate(_ workflow: VoiceWorkflow) throws {
        guard !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, workflow.name.count <= 100,
              !normalized(workflow.phrase).isEmpty, workflow.phrase.count <= 200,
              (1...20).contains(workflow.actions.count) else { throw invalid() }
        guard workflow.phrases.count <= 20, workflow.phrases.allSatisfy({ !normalized($0).isEmpty && $0.count <= 200 }),
              Set(workflow.phrases.map(normalized)).count == workflow.phrases.count else { throw invalid() }
        var delay = 0.0
        for action in workflow.actions {
            guard action.value.count <= 2000 else { throw invalid() }
            if let index = action.displayIndex {
                guard action.kind == .openApp, (1...WorkflowDisplayPolicy.maximumDisplayIndex).contains(index) else { throw invalid() }
            }
            guard action.fullscreen == nil || action.kind == .openApp else { throw invalid() }
            if let browser = action.browserID {
                guard action.kind == .openURL || action.kind == .webSearch, WorkflowBrowsers.identifiers.contains(browser) else { throw invalid() }
            }
            if let profile = action.browserProfile {
                guard action.kind != .delay, !profile.isEmpty, profile.count <= 200, !profile.contains("/"), !profile.contains("\\"), profile != ".", profile != "..", !profile.contains("\0"), WorkflowBrowsers.supportsProfiles(action.kind == .openApp ? action.value : action.browserID ?? "") else { throw invalid() }
            }
            if let separator = action.querySeparator {
                guard action.kind == .webSearch, separator.count <= 100, !normalized(separator).isEmpty, !separator.contains("\0") else { throw invalid() }
            }
            switch action.kind {
            case .openApp:
                guard action.value.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else { throw invalid() }
            case .openURL: _ = try httpsURL(action.value)
            case .webSearch:
                guard !action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid() }
            case .delay:
                guard let seconds = Double(action.value), seconds.isFinite, (0...30).contains(seconds) else { throw invalid() }
                delay += seconds
            }
        }
        guard delay <= 60 else { throw invalid() }
    }
    static func httpsURL(_ value: String) throws -> URL {
        guard let parts = URLComponents(string: value), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              let url = parts.url else { throw invalid() }
        return url
    }
    static func export(_ workflow: VoiceWorkflow) throws -> String {
        try validate(workflow)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(Document(version: 1, workflow: workflow)), as: UTF8.self)
    }
    static func imported(_ text: String) throws -> VoiceWorkflow {
        guard text.utf8.count <= 65_536 else { throw invalid() }
        let document = try JSONDecoder().decode(Document.self, from: Data(text.utf8))
        guard document.version == 1 else { throw invalid() }
        try validate(document.workflow)
        var result = document.workflow; result.id = UUID(); result.enabled = false
        result.actions = result.actions.map { var value = $0; value.id = UUID(); return value }
        return result
    }
    static func normalized(_ phrase: String) -> String {
        phrase.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
    static func match(_ text: String, in workflows: [VoiceWorkflow]) -> VoiceWorkflow? {
        let matches = workflows.filter { workflow in
            workflow.enabled && workflow.phrases.contains { phrase in
                normalized(phrase) == normalized(text) || (workflow.actions.contains { $0.kind == .webSearch && $0.value.contains("{query}") } && capturedQuery(text, phrase: phrase) != nil)
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
    static func capturedQuery(_ text: String, phrase: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        for count in 1...max(1, tokens.count) {
            if normalized(tokens.prefix(count).joined(separator: " ")) == normalized(phrase), count < tokens.count {
                let query = tokens.dropFirst(count).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized(query).isEmpty { return query }
            }
        }
        return nil
    }
    /// Split on the configured literal phrase; the default preserves bare conjunctions.
    static func searchQueries(_ query: String, separator phrase: String = "and about") throws -> [String] {
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { throw ProviderError.message("Enter a search separator word or phrase.") }
        let separator = try NSRegularExpression(pattern: #"\s+"# + words.joined(separator: #"\s+"#) + #"\s+"#, options: [.caseInsensitive])
        let range = NSRange(query.startIndex..., in: query)
        var start = query.startIndex
        var queries: [String] = []
        for match in separator.matches(in: query, range: range) {
            guard let split = Range(match.range, in: query) else { continue }
            queries.append(String(query[start..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = split.upperBound
        }
        queries.append(String(query[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        guard queries.count <= 10, queries.allSatisfy({ !normalized($0).isEmpty }) else {
            throw ProviderError.message("Speak 1–10 search subjects separated by the separator configured in Search web.")
        }
        return queries
    }
    static func invalid() -> ProviderError { .message("Invalid workflow. Use 1–20 supported actions, an explicit phrase, app bundle identifiers, HTTPS URLs without credentials/query/fragment, and at most 60 seconds total delay.") }
}
@MainActor protocol WorkflowActionRunning { func perform(_ action: WorkflowAction) async throws }
@MainActor struct SystemWorkflowRunner: WorkflowActionRunning {
    func perform(_ action: WorkflowAction) async throws {
        switch action.kind {
        case .delay: try await Task.sleep(for: .seconds(Double(action.value) ?? 0))
        case .openURL:
            try await WorkflowBrowsers.open(try WorkflowSharing.httpsURL(action.value), browser: action.browserID, profile: action.browserProfile)
        case .webSearch:
            var parts = URLComponents(string: "https://www.google.com/search")!
            parts.queryItems = [URLQueryItem(name: "q", value: action.value)]
            guard let url = parts.url else { throw ProviderError.message("Could not open search.") }
            try await WorkflowBrowsers.open(url, browser: action.browserID, profile: action.browserProfile)
        case .openApp:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.value) else { throw ProviderError.message("The selected app is not installed.") }
            let configuration = try WorkflowBrowsers.configuration(browser: action.value, profile: action.browserProfile)
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            try await DesktopWindowPlacement.apply(to: app, displayIndex: action.displayIndex, fullscreen: action.fullscreen)
        }
    }
}
@MainActor enum WorkflowExecution {
    static func run(_ workflow: VoiceWorkflow, using runner: any WorkflowActionRunning, spokenText: String? = nil) async throws {
        try WorkflowSharing.validate(workflow)
        let query = spokenText.flatMap { text in
            workflow.phrases.sorted { $0.count > $1.count }.compactMap { WorkflowSharing.capturedQuery(text, phrase: $0) }.first
        }
        let actions = try workflow.actions.flatMap { action -> [WorkflowAction] in
            if action.kind == .webSearch && action.value.contains("{query}") {
                guard let query else { throw ProviderError.message("Say a trigger followed by your search text using Record command.") }
                return try WorkflowSharing.searchQueries(query, separator: action.querySeparator ?? "and about").map { query in
                    var resolved = action
                    resolved.value = action.value.replacingOccurrences(of: "{query}", with: query)
                    return resolved
                }
            }
            return [action]
        }
        for action in actions { try Task.checkCancellation(); try await runner.perform(action) }
    }
}

extension WorkflowAction.Kind {
    var title: String { switch self { case .openApp: "Open app"; case .openURL: "Open website"; case .webSearch: "Search web"; case .delay: "Wait" } }
}
