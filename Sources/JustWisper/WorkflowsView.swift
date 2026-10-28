import SwiftUI
import AppKit

struct WorkflowsView: View {
    @EnvironmentObject var store: AppStore
    @State private var draft = VoiceWorkflow()
    @State private var sharing = ""
    @State private var notice = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Build an ordered list of actions, then say one of its phrases using Record command (followed by search text when needed). Ordinary dictation never runs workflows. Enabled matches run immediately. Use \(store.library.settings.workflowShortcut.displayName) to start and stop a command anywhere.").foregroundStyle(.secondary)
            HStack {
                Button(store.commandRecording && store.isRecording ? "Stop command recording" : "Record command") {
                    store.toggleWorkflowRecording()
                }.disabled(store.busy && !(store.commandRecording && store.isRecording))
                if store.workflowRunning { Button("Stop workflow") { store.stopWorkflow() } }
            }
            Text("Command audio uses your selected speech provider and normal History/audio retention settings. No wake word or background listening.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.library.workflows) { workflow in
                HStack {
                    VStack(alignment: .leading) {
                        Text(workflow.name).font(.headline)
                        Text("“\(workflow.phrases.joined(separator: "” / “"))” · \(workflow.actions.count) actions · \(workflow.enabled ? "Enabled" : "Disabled")").font(.caption)
                    }
                    Spacer()
                    Button("Preview / Run") { store.pendingWorkflow = workflow }
                    Button("Edit") { draft = workflow }
                    Button("Copy JSON") {
                        do { let json = try WorkflowSharing.export(workflow); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(json, forType: .string); notice = "Copied workflow JSON. Review action values before sharing." }
                        catch { notice = error.localizedDescription }
                    }
                    Button("Delete", role: .destructive) { store.library.workflows.removeAll { $0.id == workflow.id }; store.save() }
                }.disabled(store.busy).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Group {
            Divider()
            HStack { Text("Workflow editor").font(.headline); Spacer(); Button("New") { draft = VoiceWorkflow() } }
            TextField("Name", text: $draft.name)
            TextField("Exact voice phrase", text: $draft.phrase)
            ForEach(Array((draft.alternativePhrases ?? []).indices), id: \.self) { index in
                HStack {
                    TextField("Alternative voice phrase", text: Binding(get: { draft.alternativePhrases?[index] ?? "" }, set: { draft.alternativePhrases?[index] = $0 }))
                    Button("Remove phrase") { draft.alternativePhrases?.remove(at: index) }
                }
            }
            Button("Add more phrases") { if draft.alternativePhrases == nil { draft.alternativePhrases = [] }; draft.alternativePhrases?.append("") }.disabled(draft.phrases.count >= 20)
            Toggle("Enabled for command matching", isOn: $draft.enabled)
            ForEach($draft.actions) { $action in
                VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Action", selection: $action.kind) {
                        ForEach(WorkflowAction.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 190)
                    TextField(hint(action.kind), text: $action.value)
                    if action.kind == .openApp { Button("Choose app…") { chooseApp(action.id) } }
                    Button("↑") { move(action.id, offset: -1) }
                    Button("↓") { move(action.id, offset: 1) }
                    Button("Remove") { draft.actions.removeAll { $0.id == action.id } }
                }
                if action.kind == .webSearch {
                    HStack { Text("Search separator"); TextField("Word or phrase", text: Binding(get: { action.querySeparator ?? "and about" }, set: { action.querySeparator = $0 })) }
                    Text("Use {query} for search text spoken after any trigger, for example ‘search web best coffee’. Record command runs the search immediately. For separate tabs say ‘search for Winnie the Pooh and about Tom and Jerry’ (with ‘search for’ as a trigger). Separate up to 10 subjects using the separator below. The default ‘and about’ preserves ‘Tom and Jerry’; choosing ‘and’ will split that name. Replace {query} with fixed text for a saved search.").font(.caption).foregroundStyle(.secondary)
                }
                if action.kind == .openURL || action.kind == .webSearch {
                    Picker("Browser", selection: $action.browserID) {
                        Text("System default").tag(nil as String?)
                        ForEach(WorkflowBrowsers.identifiers, id: \.self) { id in
                            Text((WorkflowBrowsers.names[id] ?? id) + (NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil ? " · not installed" : "")).tag(Optional(id))
                        }
                    }.onChange(of: action.browserID) { _, _ in action.browserProfile = nil }
                }
                let browser = action.kind == .openApp ? action.value : action.browserID ?? ""
                if WorkflowBrowsers.supportsProfiles(browser) {
                    Picker("Browser profile", selection: $action.browserProfile) {
                        Text("Browser default (browser chooses)").tag(nil as String?)
                        let profiles = WorkflowBrowsers.profiles(browser)
                        ForEach(profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                        if let selected = action.browserProfile, !profiles.contains(where: { $0.id == selected }) {
                            Text("Missing profile: \(selected)").tag(Optional(selected))
                        }
                    }
                    Text("Named profiles must exist on this Mac. Missing profiles stop the workflow; Browser default uses the browser’s own choice. Safari profile selection is unavailable.").font(.caption).foregroundStyle(.secondary)
                }
                if action.kind == .openApp {
                    HStack {
                        Picker("Display", selection: $action.displayIndex) {
                            Text("App default").tag(nil as Int?)
                            ForEach(1...max(DesktopWindowPlacement.screens.count, action.displayIndex ?? 1), id: \.self) { index in
                                Text(displayLabel(index)).tag(Optional(index))
                            }
                        }.frame(maxWidth: 340)
                        Toggle("Fullscreen", isOn: Binding(get: { action.fullscreen == true }, set: { action.fullscreen = $0 }))
                    }
                    Text("Disconnected display targets use the main display. Fullscreen creates its own Space; macOS chooses its number. Numbered Space targeting is unavailable.").font(.caption).foregroundStyle(.secondary)
                }
                }.onChange(of: action.kind) { _, kind in
                    if kind != .openApp { action.displayIndex = nil; action.fullscreen = nil }
                    action.browserID = nil; action.browserProfile = nil; action.querySeparator = nil
                    if kind == .webSearch { action.value = "{query}" }
                }.onChange(of: action.value) { _, _ in
                    if action.kind == .openApp { action.browserProfile = nil }
                }
            }
            HStack {
                Button("Add action") { draft.actions.append(WorkflowAction()) }.disabled(draft.actions.count >= 20)
                Button("Save workflow") {
                    do {
                        try WorkflowSharing.validate(draft)
                        guard !store.library.workflows.contains(where: { $0.id != draft.id && !Set($0.phrases.map(WorkflowSharing.normalized)).isDisjoint(with: draft.phrases.map(WorkflowSharing.normalized)) }) else { notice = "Choose unique command phrases."; return }
                        if let index = store.library.workflows.firstIndex(where: { $0.id == draft.id }) { store.library.workflows[index] = draft }
                        else { guard store.library.workflows.count < 100 else { notice = "Limit: 100 workflows"; return }; store.library.workflows.append(draft) }
                        if store.save() { notice = "Workflow saved" }
                    } catch { notice = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
            }
            Text("Apps use bundle IDs (for example com.apple.Safari). URLs require HTTPS without credentials, queries or fragments. Search sends its text to Google. Delays are seconds, up to 30 each and 60 total. Window closing and starting ChatGPT voice are not supported.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Import shared JSON").font(.headline)
            Text("Review all values before importing or sharing. JSON contains only this workflow, including any text you type into its actions; never put secrets in action values.").font(.caption)
            TextEditor(text: $sharing).font(.system(.caption, design: .monospaced)).frame(height: 100)
            Button("Import as disabled workflow") {
                do { guard store.library.workflows.count < 100 else { notice = "Limit: 100 workflows"; return }; let workflow = try WorkflowSharing.imported(sharing); store.library.workflows.append(workflow); if store.save() { draft = workflow; sharing = ""; notice = "Imported disabled. Review and enable it explicitly." } }
                catch { notice = error.localizedDescription }
            }
            }.disabled(store.busy)
            if !notice.isEmpty { Text(notice).font(.caption).textSelection(.enabled) }
        }
    }
    private func displayLabel(_ index: Int) -> String {
        let screens = DesktopWindowPlacement.screens
        if screens.isEmpty || index > screens.count { return "Display \(index) · disconnected → Main" }
        return index == 1 ? "Main display · \(screens[0].localizedName)" : "Display \(index) · \(screens[index - 1].localizedName)"
    }
    private func chooseApp(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier,
              let index = draft.actions.firstIndex(where: { $0.id == id }) else { return }
        draft.actions[index].value = bundleID
    }
    private func hint(_ kind: WorkflowAction.Kind) -> String {
        switch kind { case .openApp: "com.apple.Safari"; case .openURL: "https://example.com"; case .webSearch: "{query} or fixed search text"; case .delay: "Seconds (0–30)" }
    }
    private func move(_ id: UUID, offset: Int) {
        guard let index = draft.actions.firstIndex(where: { $0.id == id }), draft.actions.indices.contains(index + offset) else { return }
        draft.actions.swapAt(index, index + offset)
    }
}
