import Foundation
import Combine
import CryptoKit
import CoreML
import FluidAudio

struct DiarizationAsset {
    let path: String
    let size: Int64
    let sha256: String
}

/// Downloads only a pinned, audited list of CoreML assets and publisher notices.
@MainActor
final class DiarizationModelService: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var isDownloading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = "Download offline speaker models (22 MB). Requires macOS 15 or later."
    let directory: URL
    private var task: Task<Void, Never>?
    nonisolated static let revision = "7eab74f3463c736418d0eb10296261ae581146c9"
    nonisolated static let assets: [DiarizationAsset] = [
        DiarizationAsset(path: "Embedding.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
        DiarizationAsset(path: "Embedding.mlmodelc/coremldata.bin", size: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
        DiarizationAsset(path: "Embedding.mlmodelc/metadata.json", size: 2818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
        DiarizationAsset(path: "Embedding.mlmodelc/model.mil", size: 78432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
        DiarizationAsset(path: "Embedding.mlmodelc/weights/weight.bin", size: 13412288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
        DiarizationAsset(path: "FBank.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
        DiarizationAsset(path: "FBank.mlmodelc/coremldata.bin", size: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
        DiarizationAsset(path: "FBank.mlmodelc/metadata.json", size: 3409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
        DiarizationAsset(path: "FBank.mlmodelc/model.mil", size: 15667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
        DiarizationAsset(path: "FBank.mlmodelc/weights/weight.bin", size: 1776896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
        DiarizationAsset(path: "LICENSE", size: 19759, sha256: "736763bf08829e36266b8a3bebcc041ac68575424e976490671a7e6b43a525cf"),
        DiarizationAsset(path: "NOTICE.md", size: 4247, sha256: "d8e53d399c5345cabc4763732ba096e7e18ff42c861d57b73edb73b0c9ce9356"),
        DiarizationAsset(path: "PROVENANCE.md", size: 3377, sha256: "0032bc1b7d01b6af2bb6eb8548a39c9a28fe5c1909f74166bc2ea2eb1cc27df6"),
        DiarizationAsset(path: "PldaRho.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
        DiarizationAsset(path: "PldaRho.mlmodelc/coremldata.bin", size: 763, sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
        DiarizationAsset(path: "PldaRho.mlmodelc/metadata.json", size: 2749, sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
        DiarizationAsset(path: "PldaRho.mlmodelc/model.mil", size: 7613, sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
        DiarizationAsset(path: "PldaRho.mlmodelc/weights/weight.bin", size: 200192, sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
        DiarizationAsset(path: "Segmentation.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
        DiarizationAsset(path: "Segmentation.mlmodelc/coremldata.bin", size: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
        DiarizationAsset(path: "Segmentation.mlmodelc/metadata.json", size: 3410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
        DiarizationAsset(path: "Segmentation.mlmodelc/model.mil", size: 43063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
        DiarizationAsset(path: "Segmentation.mlmodelc/weights/weight.bin", size: 5959360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
        DiarizationAsset(path: "plda-parameters.json", size: 89416, sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
        DiarizationAsset(path: "provenance.json", size: 10048, sha256: "0353430db062715c411ba32e66cb435b9caee2662bccdb298f9e5d1bae760872")
    ]

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("JustWisper/Models/Diarization", isDirectory: true)
        let location = self.directory
        task = Task { [weak self] in
            let valid = await Task.detached { (try? Self.verify(directory: location)) != nil }.value
            guard !Task.isCancelled else { return }
            self?.isInstalled = valid
            if valid { self?.status = "Offline speaker models are verified and ready." }
            self?.task = nil
        }
    }

    func install() {
        guard !isDownloading else { return }
        guard #available(macOS 15, *) else { status = "Offline speaker labeling requires macOS 15 or later."; return }
        task?.cancel()
        isDownloading = true; progress = 0
        task = Task { [weak self] in
            guard let self else { return }
            defer { isDownloading = false; task = nil }
            let staging = directory.deletingLastPathComponent().appendingPathComponent(".diarization-\(UUID().uuidString)")
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 600
            let session = URLSession(configuration: config, delegate: ModelDownloadDelegate { _ in }, delegateQueue: nil)
            defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: staging) }
            do {
                let total = Double(Self.assets.reduce(Int64(0)) { $0 + $1.size })
                var received: Int64 = 0
                for asset in Self.assets {
                    try Task.checkCancellation()
                    status = "Downloading speaker models: \(asset.path)…"
                    let url = URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/\(Self.revision)/\(asset.path)")!
                    let completed = received
                    let delegate = ModelDownloadDelegate(maximumBytes: asset.size) { [weak self] bytes in
                        Task { @MainActor in
                            self?.progress = min(0.99, Double(completed + bytes) / total)
                        }
                    }
                    let (temporary, response) = try await session.download(from: url, delegate: delegate)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ProviderError.message("The speaker model host returned an unsuccessful response.") }
                    try Self.verifyFile(temporary, asset: asset)
                    let destination = staging.appendingPathComponent(asset.path)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    received += asset.size; progress = Double(received) / total
                }
                try Task.checkCancellation()
                try Self.verify(directory: staging)
                try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if FileManager.default.fileExists(atPath: directory.path) { _ = try FileManager.default.replaceItemAt(directory, withItemAt: staging) }
                else { try FileManager.default.moveItem(at: staging, to: directory) }
                isInstalled = true; progress = 1; status = "Offline speaker models are verified and ready."
            } catch { status = Task.isCancelled ? "Speaker model download cancelled." : error.localizedDescription }
        }
    }

    func cancel() { task?.cancel() }
    func remove() throws {
        guard !isDownloading else { return }
        task?.cancel()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        isInstalled = false; progress = 0; status = "Offline speaker models removed."
    }
    nonisolated static func verify(directory: URL) throws {
        guard !assets.isEmpty else { throw ProviderError.message("Speaker model manifest is missing.") }
        for asset in assets { try verifyFile(directory.appendingPathComponent(asset.path), asset: asset) }
    }
    nonisolated static func verifyFile(_ url: URL, asset: DiarizationAsset) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == asset.size else { throw ProviderError.message("Speaker model size verification failed: \(asset.path)") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw ProviderError.message("Speaker model SHA256 verification failed: \(asset.path)") }
    }
}

struct SpeakerTimeRange: Equatable, Codable {
    var start: Double
    var end: Double
    var speaker: String
}

/// Runs the genuine segmentation → embedding → VBx clustering pipeline, without network fallback.
actor OfflineDiarizationService {
    private var manager: OfflineDiarizerManager?
    private var loadedDirectory: URL?

    func ranges(audioURL: URL, modelDirectory: URL) async throws -> [SpeakerTimeRange] {
        guard #available(macOS 15, *) else { throw ProviderError.message("Offline speaker labeling requires macOS 15 or later because macOS 14 has a CoreML BNNS crash.") }
        try Task.checkCancellation()
        try DiarizationModelService.verify(directory: modelDirectory)
        if manager == nil || loadedDirectory != modelDirectory {
            let configuration = MLModelConfiguration(); configuration.computeUnits = .all
            func load(_ name: String, cpu: Bool = false) throws -> MLModel {
                let config = cpu ? MLModelConfiguration() : configuration
                if cpu { config.computeUnits = .cpuOnly }
                return try MLModel(contentsOf: modelDirectory.appendingPathComponent(name + ".mlmodelc"), configuration: config)
            }
            let data = try Data(contentsOf: modelDirectory.appendingPathComponent("plda-parameters.json"))
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let tensors = root["tensors"] as? [String: Any], let psi = tensors["psi"] as? [String: Any], let base64 = psi["data_base64"] as? String, let bytes = Data(base64Encoded: base64), bytes.count % 4 == 0 else { throw ProviderError.message("Speaker PLDA parameters could not be read.") }
            let values: [Double] = stride(from: 0, to: bytes.count, by: 4).map { offset in
                let bits = bytes[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
                return Double(Float(bitPattern: bits))
            }
            let models = try OfflineDiarizerModels(segmentationModel: load("Segmentation"), fbankModel: load("FBank", cpu: true), embeddingModel: load("Embedding"), pldaRhoModel: load("PldaRho"), pldaPsi: values, compilationDuration: 0)
            let next = OfflineDiarizerManager(); next.initialize(models: models)
            manager = next; loadedDirectory = modelDirectory
        }
        guard let manager else { throw ProviderError.message("Speaker models are unavailable.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("JustWisper-diarize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = try await AudioConversion.audioSource(input: audioURL, directory: temporary)
        let result = try await manager.process(source)
        try Task.checkCancellation()
        return result.segments.map { SpeakerTimeRange(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId) }
    }

    func annotate(audioURL: URL, transcript: TranscriptionResult, modelDirectory: URL) async throws -> TranscriptionResult {
        let turns = try await ranges(audioURL: audioURL, modelDirectory: modelDirectory)
        return SpeakerTranscriptAlignment.annotate(transcript, ranges: turns)
    }
}

enum SpeakerTranscriptAlignment {
    /// Label an ASR segment only when one model speaker covers a majority of it.
    /// ASR segment timings are retained; words are never assigned invented timestamps.
    static func annotate(_ transcript: TranscriptionResult, ranges: [SpeakerTimeRange]) -> TranscriptionResult {
        var output = transcript
        output.segments = transcript.segments.map { segment in
            var segment = segment
            var coverage: [String: Double] = [:]
            for range in ranges {
                coverage[range.speaker, default: 0] += max(0, min(segment.end, range.end) - max(segment.start, range.start))
            }
            let duration = segment.end - segment.start
            if duration > 0, let best = coverage.max(by: { $0.value < $1.value }), best.value / duration >= 0.5 {
                let alternatives = coverage.filter { $0.key != best.key }.reduce(0.0) { $0 + $1.value }
                segment.speaker = alternatives / duration < 0.25 ? "Speaker \(best.key)" : "Multiple speakers"
            } else { segment.speaker = nil }
            return segment
        }
        return output
    }
}
