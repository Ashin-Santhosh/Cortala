import Foundation
import Testing
@testable import JustWisper

struct VaultAppStoreTests {
    @Test @MainActor func encryptedLibrarySavesAndReopensWithoutRecreatingPlaintext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var key: Data?
        let vault = LibraryVault(root: root, loadKey: { key }, saveKey: { key = $0 })
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false, libraryVault: vault)
        store.library.vocabulary.append(VocabularyEntry(phrase: "Private fixture name", replacement: ""))
        #expect(store.save())
        store.enableTranscriptEncryption()
        #expect(store.transcriptEncryptionEnabled)
        #expect(!store.hasPlaintextLibraryCopy)
        store.library.vocabulary.append(VocabularyEntry(phrase: "Second fixture", replacement: ""))
        #expect(store.save())
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        let encrypted = try Data(contentsOf: root.appendingPathComponent("library.vault"))
        #expect(encrypted.range(of: Data("Private fixture name".utf8)) == nil)
        let reopened = AppStore(root: root, startDesktop: false, loadCredentials: false, libraryVault: vault)
        #expect(reopened.library.vocabulary.map(\.phrase) == ["Private fixture name", "Second fixture"])
        #expect(reopened.error == nil)
    }
    @Test @MainActor func unavailableVaultKeyPreventsAppStoreOverwrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var key: Data?
        let vault = LibraryVault(root: root, loadKey: { key }, saveKey: { key = $0 })
        let store = AppStore(root: root, startDesktop: false, loadCredentials: false, libraryVault: vault)
        #expect(store.save())
        store.enableTranscriptEncryption()
        let original = try Data(contentsOf: vault.encryptedURL)
        key = nil
        let locked = AppStore(root: root, startDesktop: false, loadCredentials: false, libraryVault: vault)
        #expect(locked.error != nil)
        #expect(!locked.save())
        #expect(try Data(contentsOf: vault.encryptedURL) == original)
        #expect(!FileManager.default.fileExists(atPath: vault.plaintextURL.path))
    }
}
