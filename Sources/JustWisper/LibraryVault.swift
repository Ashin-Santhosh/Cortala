import CryptoKit
import Darwin
import Foundation

/// Opt-in authenticated storage for library JSON. Audio and exported files are separate.
/// No key or decrypted data belongs in errors, logs, or the ciphertext envelope.
final class LibraryVault {
    static let maximumPayloadBytes = 256 * 1024 * 1024
    private static let header = Data("JustWisperVault\0".utf8) + Data([1])
    private static let overhead = header.count + 12 + 16
    private let root: URL
    private let loadKey: () throws -> Data?
    private let saveKey: (Data) throws -> Void

    var encryptedURL: URL { root.appendingPathComponent("library.vault") }
    var plaintextURL: URL { root.appendingPathComponent("library.json") }
    /// Includes unsafe/broken symlinks, so an existing vault always fails closed.
    var isEnabled: Bool { Self.exists(encryptedURL) }
    var plaintextRemains: Bool { Self.exists(plaintextURL) }

    init(root: URL, loadKey: (() throws -> Data?)? = nil, saveKey: ((Data) throws -> Void)? = nil) {
        self.root = root.standardizedFileURL
        let identity = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let account = "storage-encryption-key-v1-" + identity
        self.loadKey = loadKey ?? {
            let value = try KeychainService.load(account: account)
            guard !value.isEmpty else { return nil }
            guard let key = Data(base64Encoded: value), key.count == 32 else { throw VaultError.keyUnavailable }
            return key
        }
        self.saveKey = saveKey ?? { try KeychainService.save($0.base64EncodedString(), account: account) }
    }

    func load() throws -> Data? {
        var rootInfo = stat()
        if lstat(root.path, &rootInfo) != 0 {
            if errno == ENOENT { return nil }
            throw VaultError.storageUnavailable
        }
        return try withRoot(create: false) { directory in
            try validateTargets(directory)
            if let ciphertext = try read("library.vault", directory: directory, maximum: Self.maximumPayloadBytes + Self.overhead) {
                return try decrypt(ciphertext, key: existingKey())
            }
            return try read("library.json", directory: directory, maximum: Self.maximumPayloadBytes)
        }
    }

    func save(_ data: Data) throws {
        guard data.count <= Self.maximumPayloadBytes else { throw VaultError.tooLarge }
        try withRoot(create: true) { directory in
            try validateTargets(directory)
            if let current = try read("library.vault", directory: directory, maximum: Self.maximumPayloadBytes + Self.overhead) {
                let key = try existingKey()
                // A missing/wrong key or damaged vault must never be overwritten.
                _ = try decrypt(current, key: key)
                try atomicWrite(encrypt(data, key: key), name: "library.vault", directory: directory, replace: true)
            } else {
                try atomicWrite(data, name: "library.json", directory: directory, replace: true)
            }
        }
    }

    /// Encryption is authoritative when both files exist. Cleanup is permitted
    /// only when the remaining plaintext matches that verified encrypted library.
    func enableEncryption() throws {
        try withRoot(create: false) { directory in
            try validateTargets(directory)
            if let current = try read("library.vault", directory: directory, maximum: Self.maximumPayloadBytes + Self.overhead) {
                let data = try decrypt(current, key: existingKey())
                try removeMatchingPlaintext(data, directory: directory)
                return
            }
            guard let plaintext = try read("library.json", directory: directory, maximum: Self.maximumPayloadBytes) else { throw VaultError.noLibrary }
            let key: Data
            do {
                if let stored = try loadKey() {
                    guard stored.count == 32 else { throw VaultError.keyUnavailable }
                    key = stored
                } else {
                    key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    // Device-only unlocked Keychain persistence precedes ciphertext.
                    try saveKey(key)
                    guard try loadKey() == key else { throw VaultError.keyUnavailable }
                }
            } catch { throw VaultError.keyUnavailable }
            try atomicWrite(encrypt(plaintext, key: key), name: "library.vault", directory: directory, replace: false)
            guard let written = try read("library.vault", directory: directory, maximum: Self.maximumPayloadBytes + Self.overhead),
                  try decrypt(written, key: key) == plaintext else { throw VaultError.authenticationFailed }
            try removeMatchingPlaintext(plaintext, directory: directory)
        }
    }

    private func existingKey() throws -> Data {
        do {
            guard let key = try loadKey(), key.count == 32 else { throw VaultError.keyUnavailable }
            return key
        } catch { throw VaultError.keyUnavailable }
    }

    private func encrypt(_ data: Data, key: Data) throws -> Data {
        do {
            let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), authenticating: Self.header)
            guard let combined = box.combined else { throw VaultError.authenticationFailed }
            return Self.header + combined
        } catch { throw VaultError.authenticationFailed }
    }

    private func decrypt(_ data: Data, key: Data) throws -> Data {
        guard data.count >= Self.overhead, data.count <= Self.maximumPayloadBytes + Self.overhead,
              data.prefix(Self.header.count) == Self.header else { throw VaultError.invalidEnvelope }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(Self.header.count))
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Self.header)
        } catch { throw VaultError.authenticationFailed }
    }

    private func removeMatchingPlaintext(_ data: Data, directory: Int32) throws {
        guard let plaintext = try read("library.json", directory: directory, maximum: Self.maximumPayloadBytes) else { return }
        guard plaintext == data else { throw VaultError.plaintextConflict }
        guard unlinkat(directory, "library.json", 0) == 0 else { throw VaultError.cleanupFailed }
        _ = fsync(directory)
    }

    private func withRoot<T>(create: Bool, _ operation: (Int32) throws -> T) throws -> T {
        if !Self.exists(root) {
            guard create else { throw VaultError.noLibrary }
            do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { throw VaultError.storageUnavailable }
        }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw VaultError.unsafeFile }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              fchmod(directory, 0o700) == 0 else { throw VaultError.unsafeFile }
        return try operation(directory)
    }

    private func validateTargets(_ directory: Int32) throws {
        try validate("library.json", directory: directory)
        try validate("library.vault", directory: directory)
    }

    private func validate(_ name: String, directory: Int32) throws {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw VaultError.storageUnavailable
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else { throw VaultError.unsafeFile }
    }

    private func read(_ name: String, directory: Int32, maximum: Int) throws -> Data? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw VaultError.unsafeFile
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw VaultError.unsafeFile }
        guard info.st_size >= 0, info.st_size <= maximum else { throw VaultError.tooLarge }
        guard fchmod(descriptor, 0o600) == 0 else { throw VaultError.storageUnavailable }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw VaultError.storageUnavailable
            }
            if count == 0 { break }
            guard count <= maximum - result.count else { throw VaultError.tooLarge }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    private func atomicWrite(_ data: Data, name: String, directory: Int32, replace: Bool) throws {
        let temporary = ".library-vault-" + UUID().uuidString
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw VaultError.storageUnavailable }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw VaultError.storageUnavailable
                }
                guard count > 0 else { throw VaultError.storageUnavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw VaultError.storageUnavailable }
        try validate(name, directory: directory)
        if replace {
            guard renameat(directory, temporary, directory, name) == 0 else { throw VaultError.storageUnavailable }
        } else {
            // Atomic create-if-absent prevents replacing a concurrently added vault.
            guard linkat(directory, temporary, directory, name, 0) == 0 else { throw VaultError.storageUnavailable }
            guard unlinkat(directory, temporary, 0) == 0 else { throw VaultError.storageUnavailable }
        }
        _ = fsync(directory)
    }

    private static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    enum VaultError: LocalizedError {
        case keyUnavailable, authenticationFailed, invalidEnvelope, unsafeFile, storageUnavailable, tooLarge, noLibrary, cleanupFailed, plaintextConflict
        var errorDescription: String? {
            switch self {
            case .keyUnavailable: return "The library encryption key is unavailable. Unlock this Mac's Keychain; an existing encrypted library will not be reset."
            case .authenticationFailed: return "The encrypted library could not be authenticated. Its contents have not been replaced."
            case .invalidEnvelope: return "The encrypted library format is invalid or unsupported. Its contents have not been replaced."
            case .unsafeFile: return "The library location must contain private regular files owned by this user, without links."
            case .storageUnavailable: return "The library could not be safely read or written. Existing library data has been preserved."
            case .tooLarge: return "The library exceeds the supported storage size. Existing library data has been preserved."
            case .noLibrary: return "Save the library before enabling encryption."
            case .cleanupFailed: return "The encrypted library is ready, but the previous plaintext library could not be removed."
            case .plaintextConflict: return "Both encrypted and plaintext libraries exist with different contents. The encrypted library is authoritative; both files have been preserved for review."
            }
        }
    }
}
