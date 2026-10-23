import Darwin
import Foundation
import Testing
@testable import JustWisper

struct LibraryVaultTests {
    private final class Keys {
        var value: Data?
        var writes = 0
        func vault(_ root: URL) -> LibraryVault {
            LibraryVault(root: root, loadKey: { self.value }, saveKey: { self.value = $0; self.writes += 1 })
        }
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JustWisper-vault-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func legacyLibraryStaysPlainUntilExplicitMigration() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = Keys()
        let vault = keys.vault(root)
        let payload = Data(#"{"history":[{"raw":"private transcript"}]}"#.utf8)
        #expect(try vault.load() == nil)
        #expect(!vault.isEnabled)
        #expect(throws: (any Error).self) { try vault.enableEncryption() }
        try vault.save(payload)
        #expect(!vault.isEnabled)
        #expect(vault.plaintextRemains)
        #expect(try vault.load() == payload)
        #expect(keys.writes == 0)
        #expect(try Data(contentsOf: vault.plaintextURL) == payload)
    }

    @Test func migrationRoundTripRemovesPlaintextAndUsesPrivatePermissions() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = Keys()
        let vault = keys.vault(root)
        let payload = Data(#"{"history":[{"raw":"private sentinel transcript"}]}"#.utf8)
        try vault.save(payload)
        try vault.enableEncryption()
        #expect(vault.isEnabled)
        #expect(!vault.plaintextRemains)
        #expect(keys.value?.count == 32)
        #expect(keys.writes == 1)
        #expect(try vault.load() == payload)
        let ciphertext = try Data(contentsOf: vault.encryptedURL)
        #expect(ciphertext.range(of: Data("private sentinel transcript".utf8)) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["library.vault"])
        let rootPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(atPath: vault.encryptedURL.path)[.posixPermissions] as? NSNumber
        #expect(rootPermissions?.intValue == 0o700)
        #expect(filePermissions?.intValue == 0o600)
        let next = Data(#"{"history":[{"raw":"new final text"}]}"#.utf8)
        try vault.save(next)
        #expect(try vault.load() == next)
        #expect(!vault.plaintextRemains)
        #expect(try Data(contentsOf: vault.encryptedURL) != ciphertext)
        #expect(keys.writes == 1)
    }

    @Test func tamperedCiphertextCannotBeLoadedOrOverwritten() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = Keys(), payload = Data("private authenticated payload".utf8)
        let vault = keys.vault(root)
        try vault.save(payload)
        try vault.enableEncryption()
        var damaged = try Data(contentsOf: vault.encryptedURL)
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: vault.encryptedURL)
        #expect(throws: (any Error).self) { try vault.load() }
        #expect(throws: (any Error).self) { try vault.save(Data("replacement".utf8)) }
        #expect(throws: (any Error).self) { try vault.enableEncryption() }
        #expect(try Data(contentsOf: vault.encryptedURL) == damaged)
        #expect(keys.writes == 1)
    }

    @Test func missingOrWrongKeyNeverRegeneratesOrResetsAnExistingVault() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = Keys(), payload = Data("private key-bound payload".utf8)
        let vault = keys.vault(root)
        try vault.save(payload)
        try vault.enableEncryption()
        let originalKey = keys.value
        let originalCiphertext = try Data(contentsOf: vault.encryptedURL)
        for unavailable in [nil, Data(repeating: 0x5a, count: 32), Data([1])] as [Data?] {
            keys.value = unavailable
            #expect(throws: (any Error).self) { try vault.load() }
            #expect(throws: (any Error).self) { try vault.save(Data("replacement".utf8)) }
            #expect(throws: (any Error).self) { try vault.enableEncryption() }
            #expect(try Data(contentsOf: vault.encryptedURL) == originalCiphertext)
            #expect(keys.writes == 1)
        }
        keys.value = originalKey
        #expect(try vault.load() == payload)
    }

    @Test func keyPersistenceFailurePreservesTheOnlyUsablePlaintext() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        enum Failure: Error { case denied }
        let vault = LibraryVault(root: root, loadKey: { nil }, saveKey: { _ in throw Failure.denied })
        let payload = Data("private original before key failure".utf8)
        try vault.save(payload)
        #expect(throws: (any Error).self) { try vault.enableEncryption() }
        #expect(!vault.isEnabled)
        #expect(vault.plaintextRemains)
        #expect(try Data(contentsOf: vault.plaintextURL) == payload)
        #expect(try vault.load() == payload)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["library.json"])
    }

    @Test func existingVaultIsAuthoritativeAndPlaintextCleanupRequiresMatchingData() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = Keys(), payload = Data("authoritative encrypted library".utf8)
        let vault = keys.vault(root)
        try vault.save(payload)
        try vault.enableEncryption()
        let unrelated = Data("different remaining plaintext library".utf8)
        try unrelated.write(to: vault.plaintextURL)
        #expect(vault.isEnabled && vault.plaintextRemains)
        #expect(try vault.load() == payload)
        #expect(throws: (any Error).self) { try vault.enableEncryption() }
        #expect(try Data(contentsOf: vault.plaintextURL) == unrelated)
        #expect(try vault.load() == payload)
        try payload.write(to: vault.plaintextURL)
        try vault.enableEncryption()
        #expect(!vault.plaintextRemains)
        #expect(keys.writes == 1)
    }

    @Test func symlinkAndNonregularTargetsAreRejectedWithoutFollowingThem() throws {
        let root = try directory(), elsewhere = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
        let outside = elsewhere.appendingPathComponent("outside.json")
        let payload = Data("must not change outside the library".utf8)
        try payload.write(to: outside)
        let keys = Keys()
        let vault = keys.vault(root)
        for name in ["library.json", "library.vault"] {
            let target = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            #expect(throws: (any Error).self) { try vault.load() }
            #expect(throws: (any Error).self) { try vault.save(Data("replacement".utf8)) }
            #expect(throws: (any Error).self) { try vault.enableEncryption() }
            #expect(try Data(contentsOf: outside) == payload)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            #expect(throws: (any Error).self) { try vault.load() }
            #expect(throws: (any Error).self) { try vault.save(Data("replacement".utf8)) }
            #expect(throws: (any Error).self) { try vault.enableEncryption() }
            try FileManager.default.removeItem(at: target)
            let created = mkfifo(target.path, 0o600)
            #expect(created == 0)
            #expect(throws: (any Error).self) { try vault.load() }
            #expect(throws: (any Error).self) { try vault.save(Data("replacement".utf8)) }
            #expect(throws: (any Error).self) { try vault.enableEncryption() }
            try FileManager.default.removeItem(at: target)
        }
        #expect(keys.writes == 0)
    }

    @Test func hardlinkedLibraryAndSymlinkRootAreRejected() throws {
        let root = try directory(), elsewhere = try directory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
        let outside = elsewhere.appendingPathComponent("original.json")
        let payload = Data("private outside original".utf8)
        try payload.write(to: outside)
        let target = root.appendingPathComponent("library.json")
        try FileManager.default.linkItem(at: outside, to: target)
        let vault = Keys().vault(root)
        #expect(throws: (any Error).self) { try vault.load() }
        #expect(throws: (any Error).self) { try vault.enableEncryption() }
        try FileManager.default.removeItem(at: target)
        let linkedRoot = elsewhere.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        let linkedVault = Keys().vault(linkedRoot)
        #expect(throws: (any Error).self) { try linkedVault.save(payload) }
        #expect(try Data(contentsOf: outside) == payload)
    }

    @Test func oversizedSparsePlaintextIsRejectedBeforeReadingOrMigration() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = Keys()
        let vault = keys.vault(root)
        let descriptor = open(vault.plaintextURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let result = ftruncate(descriptor, off_t(LibraryVault.maximumPayloadBytes + 1))
        #expect(result == 0)
        #expect(throws: (any Error).self) { try vault.load() }
        #expect(throws: (any Error).self) { try vault.enableEncryption() }
        #expect(!vault.isEnabled)
        #expect(vault.plaintextRemains)
        #expect(keys.writes == 0)
    }
}
