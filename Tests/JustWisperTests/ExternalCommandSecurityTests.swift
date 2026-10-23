import Foundation
import Testing
@testable import JustWisper

struct ExternalCommandSecurityTests {
    @Test @MainActor func externalRecordingLinksRequireApprovalAndCanBeDismissed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        store.executeCommandURL(URL(string: "justwisper://start")!)
        #expect(store.pendingExternalCommand == .start(nil))
        #expect(!store.busy)
        store.dismissExternalCommand()
        #expect(store.pendingExternalCommand == nil)
        #expect(!store.busy)
    }
    @Test @MainActor func expiredOrSupersededCommandsCannotApply() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        let email = try #require(store.library.modes.first { $0.name == "Email" })
        store.executeCommandURL(URL(string: "justwisper://mode?id=\(email.id.uuidString)")!)
        store.approveExternalCommand(now: Date().addingTimeInterval(120))
        #expect(store.selectedMode.id != email.id)
        store.executeCommandURL(URL(string: "justwisper://mode?id=\(email.id.uuidString)")!)
        store.cancel()
        store.approveExternalCommand()
        #expect(store.selectedMode.id != email.id)
    }
    @Test @MainActor func incomingFileDoesNotTranscribeUntilApproved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        let audio = root.appendingPathComponent("external.wav")
        store.requestIncomingImport(audio)
        #expect(store.pendingImportURL == audio)
        #expect(!store.busy && store.library.history.isEmpty)
        store.dismissIncomingImport()
        #expect(store.pendingImportURL == nil)
    }
}
