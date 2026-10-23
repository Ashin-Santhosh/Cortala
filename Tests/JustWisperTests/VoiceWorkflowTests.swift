import Foundation
import Testing
@testable import JustWisper

struct VoiceWorkflowTests {
    func sample() -> VoiceWorkflow { VoiceWorkflow(name: "Research", phrase: "begin research", enabled: true, actions: [WorkflowAction(kind: .openApp, value: "com.apple.Safari"), WorkflowAction(kind: .webSearch, value: "Swift concurrency"), WorkflowAction(kind: .delay, value: "1")]) }
    @Test func testImportResetsIdentityAndDisables() throws {
        let original = sample(), imported = try WorkflowSharing.imported(WorkflowSharing.export(original))
        #expect(original.id != imported.id)
        #expect(!(imported.enabled))
        #expect(original.actions[0].id != imported.actions[0].id)
        #expect(original.actions.map(\.value) == imported.actions.map(\.value))
    }
    @Test func testRejectUnsafeURLsAndUnboundedDelay() throws {
        for value in ["file:///tmp/test", "http://example.com", "javascript:alert(1)", "https://user:secret@example.com", "https://example.com/?token=secret", "https://example.com/#secret"] {
            var workflow = sample(); workflow.actions = [WorkflowAction(kind: .openURL, value: value)]
            #expect(throws: (any Error).self) { try WorkflowSharing.validate(workflow) }
        }
        for value in ["nan", "inf", "-1", "31"] {
            var workflow = sample(); workflow.actions = [WorkflowAction(kind: .delay, value: value)]
            #expect(throws: (any Error).self) { try WorkflowSharing.validate(workflow) }
        }
    }
    @Test func testActionAndTotalDelayLimits() {
        var workflow = sample()
        workflow.actions = Array(repeating: WorkflowAction(kind: .delay, value: "30"), count: 3)
        #expect(throws: (any Error).self) { try WorkflowSharing.validate(workflow) }
        workflow.actions = Array(repeating: WorkflowAction(kind: .webSearch, value: "test"), count: 21)
        #expect(throws: (any Error).self) { try WorkflowSharing.validate(workflow) }
        workflow.actions = []
        #expect(throws: (any Error).self) { try WorkflowSharing.validate(workflow) }
    }
    @Test @MainActor func testCancellationPreventsRemainingActions() async throws {
        let runner = FakeWorkflowRunner()
        runner.cancelAfterFirst = true
        let task = Task { try await WorkflowExecution.run(sample(), using: runner) }
        while runner.values.isEmpty { await Task.yield() }
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") } catch is CancellationError { } catch { Issue.record("Unexpected error") }
        #expect(runner.values.count == 1)
    }
    @Test func testUnknownVersionKindAndOversizeRejected() throws {
        let json = try WorkflowSharing.export(sample())
        #expect(throws: (any Error).self) { try WorkflowSharing.imported(json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")) }
        #expect(throws: (any Error).self) { try WorkflowSharing.imported(json.replacingOccurrences(of: "openApp", with: "shell")) }
        #expect(throws: (any Error).self) { try WorkflowSharing.imported(String(repeating: " ", count: 65_537)) }
    }
    @Test func testExactUniqueEnabledMatching() {
        var workflow = sample()
        #expect(WorkflowSharing.match("Begin research!", in: [workflow]) != nil)
        #expect(WorkflowSharing.match("please begin research", in: [workflow]) == nil)
        #expect(WorkflowSharing.match(workflow.phrase, in: [workflow, workflow]) == nil)
        workflow.enabled = false
        #expect(WorkflowSharing.match(workflow.phrase, in: [workflow]) == nil)
    }
    @Test @MainActor func testRunnerKeepsOrderAndStopsOnFailure() async throws {
        let runner = FakeWorkflowRunner()
        try await WorkflowExecution.run(sample(), using: runner)
        #expect(runner.values == sample().actions.map(\.value))
        let failing = FakeWorkflowRunner(); failing.failAt = 1
        do { try await WorkflowExecution.run(sample(), using: failing); Issue.record("Expected failure") } catch { }
        #expect(failing.values.count == 2)
    }
    @Test @MainActor func testOnlyExplicitCommandProcessingExecutesWithoutPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        store.library.workflows = [sample()]
        let runner = FakeWorkflowRunner()
        store.workflowRunner = runner
        store.process(root.appendingPathComponent("unused.wav"), stableRaw: "begin research", isCommand: true)
        while store.isProcessing { await Task.yield() }
        #expect(store.pendingWorkflow == nil)
        #expect(runner.values == sample().actions.map(\.value))
        #expect(store.latestText == "")
        #expect(!(store.workflowRunning))
        store.pendingWorkflow = nil
        store.process(root.appendingPathComponent("unused.wav"), stableRaw: "begin research")
        while store.isProcessing { await Task.yield() }
        #expect(store.pendingWorkflow == nil)
        #expect(!(store.workflowRunning))
        #expect(store.latestText == "begin research")
        #expect(runner.values.count == sample().actions.count)
    }
    @Test @MainActor func testUnmatchedDisabledAndAmbiguousCommandsNeverExecute() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        let runner = FakeWorkflowRunner()
        store.workflowRunner = runner
        var disabled = sample(); disabled.enabled = false
        for workflows in [[disabled], [sample(), sample()], [sample()]] {
            store.library.workflows = workflows
            let phrase = workflows.count == 1 && workflows[0].enabled ? "unknown command" : "begin research"
            store.process(root.appendingPathComponent("unused.wav"), stableRaw: phrase, isCommand: true)
            while store.isProcessing { await Task.yield() }
            #expect(runner.values.isEmpty)
            #expect(store.pendingWorkflow == nil)
            #expect(store.error == nil)
        }
    }
    @Test @MainActor func testWorkflowShortcutDoesNotStopOrdinaryRecording() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        store.isRecording = true
        store.toggleWorkflowRecording()
        #expect(store.isRecording)
        #expect(!store.commandRecording)
        store.isRecording = false
    }
    @Test func testWorkflowShortcutDefaultsAndCollisions() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(settings.workflowShortcut == .workflow)
        #expect(HotKeySpec.validationError(toggle: .toggle, hold: .hold, modes: [], switcher: .modeSwitcher) == nil)
        #expect(HotKeySpec.validationError(toggle: .workflow, hold: .hold, modes: []) != nil)
        var mode = DictationMode(name: "Workflow collision", icon: "sparkles")
        mode.shortcut = .workflow
        #expect(HotKeySpec.validationError(toggle: .toggle, hold: .hold, modes: [mode]) != nil)
        var customized = settings
        customized.workflowShortcut = .modeSwitcher
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(customized))
        #expect(roundTrip.workflowShortcut == .modeSwitcher)
    }
    @Test func testDisplayPlacementFallbackAndJSONCompatibility() throws {
        #expect(WorkflowDisplayPolicy.resolvedIndex(requested: 2, displayCount: 3) == 2)
        #expect(WorkflowDisplayPolicy.resolvedIndex(requested: 3, displayCount: 1) == 1)
        #expect(WorkflowDisplayPolicy.resolvedIndex(requested: 1, displayCount: 0) == 1)
        let legacy = try JSONDecoder().decode(WorkflowAction.self, from: Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"kind\":\"openApp\",\"value\":\"com.apple.Safari\"}".utf8))
        #expect(legacy.displayIndex == nil)
        #expect(legacy.fullscreen == nil)
        var workflow = sample()
        workflow.actions[0].displayIndex = 3
        workflow.actions[0].fullscreen = true
        let imported = try WorkflowSharing.imported(WorkflowSharing.export(workflow))
        #expect(imported.actions[0].displayIndex == 3)
        #expect(imported.actions[0].fullscreen == true)
        #expect(!imported.enabled)
        #expect(imported.id != workflow.id)
        for invalid in [0, -1, 33] {
            workflow.actions[0].displayIndex = invalid
            #expect(throws: (any Error).self) { try WorkflowSharing.validate(workflow) }
        }
        workflow.actions[0].displayIndex = 1
        workflow.actions[1].fullscreen = true
        #expect(throws: (any Error).self) { try WorkflowSharing.validate(workflow) }
    }
    @Test @MainActor func testPlacementOptionsStayInActionOrderWithFakeRunner() async throws {
        var workflow = sample()
        workflow.actions[0].displayIndex = 2
        workflow.actions[0].fullscreen = true
        let runner = FakeWorkflowRunner()
        try await WorkflowExecution.run(workflow, using: runner)
        #expect(runner.actions == workflow.actions)
    }
    @Test func testLegacyLibraryDefaultsWithoutLosingHistory() throws {
        let library = try JSONDecoder().decode(LibraryState.self, from: Data("{\"history\":[],\"settings\":{}}".utf8))
        #expect(library.workflows.isEmpty)
    }
}
@MainActor private final class FakeWorkflowRunner: WorkflowActionRunning {
    var values: [String] = []
    var actions: [WorkflowAction] = []
    var failAt: Int?
    var cancelAfterFirst = false
    func perform(_ action: WorkflowAction) async throws {
        values.append(action.value)
        actions.append(action)
        if cancelAfterFirst { try await Task.sleep(for: .seconds(30)) }
        if values.count - 1 == failAt { throw ProviderError.message("Test failure") }
    }
}
