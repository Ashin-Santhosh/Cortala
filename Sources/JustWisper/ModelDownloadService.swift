import Foundation
import Combine
import CryptoKit

struct LocalModelDescriptor: Identifiable, Equatable {
    var id: String
    var name: String
    var filename: String
    var byteCount: Int64
    var sha256: String
    var downloadURL: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")! }
    /// SHA256 and byte counts verified against the publisher's Git LFS metadata.
    static let catalog: [Self] = [
        Self(id: "tiny", name: "Tiny · fastest", filename: "ggml-tiny.bin", byteCount: 77_691_713, sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
        Self(id: "base", name: "Base · lightweight", filename: "ggml-base.bin", byteCount: 147_951_465, sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
        Self(id: "small", name: "Small · balanced", filename: "ggml-small.bin", byteCount: 487_601_967, sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
        Self(id: "medium", name: "Medium · higher accuracy", filename: "ggml-medium.bin", byteCount: 1_533_763_059, sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208")
    ]
}

@MainActor
final class ModelDownloadService: ObservableObject {
    static let catalog = LocalModelDescriptor.catalog
    @Published private(set) var progress: Double = 0
    @Published private(set) var activeModelID: String?
    @Published private(set) var status = "Choose a model to download."
    @Published private(set) var installed: [String: URL] = [:]
    private var task: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?
    @Published private(set) var isChecking = false
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JustWisper/Models", isDirectory: true)
        refresh()
    }

    func installedURL(for model: LocalModelDescriptor) -> URL? { installed[model.id] }

    func refresh() {
        verificationTask?.cancel()
        installed = [:]
        isChecking = true
        let directory = self.directory
        verificationTask = Task { [weak self] in
            var verifiedFiles: [String: URL] = [:]
            for model in Self.catalog {
                if Task.isCancelled { return }
                let url = directory.appendingPathComponent(model.filename)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let verification = Task.detached { try Self.verifyFile(url, model: model) }
                do {
                    try await withTaskCancellationHandler(operation: { try await verification.value }, onCancel: { verification.cancel() })
                    verifiedFiles[model.id] = url
                } catch { /* Corrupt or incomplete files are never shown as installed. */ }
            }
            guard !Task.isCancelled else { return }
            self?.installed.merge(verifiedFiles) { current, _ in current }
            self?.isChecking = false
        }
    }

    func download(_ model: LocalModelDescriptor) {
        guard activeModelID == nil, let verified = Self.catalog.first(where: { $0 == model }) else { return }
        activeModelID = verified.id
        progress = 0
        status = "Downloading \(verified.name)…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { activeModelID = nil; task = nil }
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let delegate = ModelDownloadDelegate(maximumBytes: verified.byteCount) { [weak self] received in
                Task { @MainActor in
                    guard self?.activeModelID == verified.id else { return }
                    self?.progress = min(0.99, Double(received) / Double(verified.byteCount))
                }
            }
            do {
                let (temporary, response) = try await session.download(from: verified.downloadURL, delegate: delegate)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw ProviderError.message("The model host returned an unsuccessful response.")
                }
                try Task.checkCancellation()
                status = "Verifying SHA256…"
                let verification = Task.detached { try Self.verifyFile(temporary, model: verified) }
                try await withTaskCancellationHandler(operation: { try await verification.value }, onCancel: { verification.cancel() })
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let destination = directory.appendingPathComponent(verified.filename)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else { try FileManager.default.moveItem(at: temporary, to: destination) }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                progress = 1
                installed[verified.id] = destination
                status = "\(verified.name) is ready."
            } catch is CancellationError { status = "Download cancelled." }
            catch {
                status = Task.isCancelled ? "Download cancelled." : error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }

    func remove(_ model: LocalModelDescriptor) throws {
        guard activeModelID != model.id, Self.catalog.contains(model) else { return }
        let url = directory.appendingPathComponent(model.filename)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        installed.removeValue(forKey: model.id)
    }

    nonisolated static func verifyFile(_ url: URL, model: LocalModelDescriptor) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == model.byteCount else {
            throw ProviderError.message("The downloaded model size does not match the publisher's metadata.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard checksum == model.sha256 else { throw ProviderError.message("The downloaded model failed SHA256 verification. Please retry.") }
    }
}

final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: (Int64) -> Void
    let maximumBytes: Int64?
    init(maximumBytes: Int64? = nil, progress: @escaping (Int64) -> Void) { self.maximumBytes = maximumBytes; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let maximumBytes, totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel(); return }
        progress(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host?.lowercased() ?? ""
        let trusted = host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
        completionHandler(request.url?.scheme == "https" && trusted ? request : nil)
    }
}
