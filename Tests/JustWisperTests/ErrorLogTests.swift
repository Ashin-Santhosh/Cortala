import Foundation
import Testing
@testable import JustWisper

struct ErrorLogTests {
    @Test @MainActor func errorsAreBoundedDeduplicatedAndClearableWithoutTouchingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false)
        store.clearErrorLog()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let history = try encoder.encode(store.library.history)
        for index in 0..<110 { store.error = "Issue \(index)" }
        #expect(store.errorEvents.count == 100)
        #expect(store.errorEvents.first?.message == "Issue 10")
        store.error = "Issue 109"
        #expect(store.errorEvents.count == 100)
        store.error = nil
        #expect(store.errorEvents.count == 100)
        store.clearErrorLog()
        #expect(store.errorEvents.isEmpty)
        #expect(store.error == nil)
        #expect(try encoder.encode(store.library.history) == history)
    }
}
