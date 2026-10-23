import AppKit
import Foundation

struct VoiceWorkflow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "New workflow"
    var phrase = ""
    var enabled = false
    var actions: [WorkflowAction] = []
}
struct WorkflowAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case openApp, openURL, webSearch, delay }
    var id = UUID()
    var kind: Kind = .openURL
    var value = ""
    var displayIndex: Int? = nil
    var fullscreen: Bool? = nil
    var summary: String {
        var result = "\(kind.title): \(value)"
        if kind == .openApp {
            if let displayIndex { result += displayIndex == 1 ? " · Main display" : " · Display \(displayIndex) (main if disconnected)" }
            if let fullscreen { result += fullscreen ? " · Fullscreen (macOS chooses Space)" : " · Windowed" }
        }
        return result
    }
}
enum WorkflowSharing {
    struct Document: Codable { var version: Int; var workflow: VoiceWorkflow }
    static func validate(_ workflow: VoiceWorkflow) throws {
        guard !workflow.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, workflow.name.count <= 100,
              !normalized(workflow.phrase).isEmpty, workflow.phrase.count <= 200,
              (1...20).contains(workflow.actions.count) else { throw invalid() }
        var delay = 0.0
        for action in workflow.actions {
            guard action.value.count <= 2000 else { throw invalid() }
            if let index = action.displayIndex {
                guard action.kind == .openApp, (1...WorkflowDisplayPolicy.maximumDisplayIndex).contains(index) else { throw invalid() }
            }
            guard action.fullscreen == nil || action.kind == .openApp else { throw invalid() }
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
        let matches = workflows.filter { $0.enabled && normalized($0.phrase) == normalized(text) }
        return matches.count == 1 ? matches[0] : nil
    }
    static func invalid() -> ProviderError { .message("Invalid workflow. Use 1–20 supported actions, an explicit phrase, app bundle identifiers, HTTPS URLs without credentials/query/fragment, and at most 60 seconds total delay.") }
}
@MainActor protocol WorkflowActionRunning { func perform(_ action: WorkflowAction) async throws }
@MainActor struct SystemWorkflowRunner: WorkflowActionRunning {
    func perform(_ action: WorkflowAction) async throws {
        switch action.kind {
        case .delay: try await Task.sleep(for: .seconds(Double(action.value) ?? 0))
        case .openURL:
            guard NSWorkspace.shared.open(try WorkflowSharing.httpsURL(action.value)) else { throw ProviderError.message("Could not open URL.") }
        case .webSearch:
            var parts = URLComponents(string: "https://www.google.com/search")!
            parts.queryItems = [URLQueryItem(name: "q", value: action.value)]
            guard let url = parts.url, NSWorkspace.shared.open(url) else { throw ProviderError.message("Could not open search.") }
        case .openApp:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: action.value) else { throw ProviderError.message("The selected app is not installed.") }
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            try await DesktopWindowPlacement.apply(to: app, displayIndex: action.displayIndex, fullscreen: action.fullscreen)
        }
    }
}
@MainActor enum WorkflowExecution {
    static func run(_ workflow: VoiceWorkflow, using runner: any WorkflowActionRunning) async throws {
        try WorkflowSharing.validate(workflow)
        for action in workflow.actions { try Task.checkCancellation(); try await runner.perform(action) }
    }
}

extension WorkflowAction.Kind {
    var title: String { switch self { case .openApp: "Open app"; case .openURL: "Open website"; case .webSearch: "Search web"; case .delay: "Wait" } }
}
