import Foundation
import CryptoKit

/// Configuration-only exchange through a user-selected folder. No network client,
/// history, recordings, Keychain material, or machine permissions are synchronized.
@MainActor
final class ConfigurationSyncService {
    struct Snapshot: Codable {
        var formatVersion = 2
        var savedAt = Date()
        var revisionID: UUID?
        var parentRevisionID: UUID?
        var configurationHash: String?
        var configuration: LibraryState
    }
    enum PushResult { case saved, conflict(URL) }
    enum InitialChoice { case useLocal, useShared, resume }
    private struct Baseline: Codable {
        var localHash: String
        var remoteHash: String
        var revisionID: UUID?
    }
    private struct AutomaticSession {
        var folder: URL
        var baseline: Baseline
        var localState: () -> LibraryState
        var applyRemote: (LibraryState) throws -> Void
        var onStatus: (String) -> Void
    }
    private var observed: [String: String] = [:]
    private let filename = "JustWisper-configuration.json"
    private let stateDirectory: URL
    private var automatic: AutomaticSession?
    private var timer: Timer?
    private var lastStatus: String?
    private(set) var automaticRunning = false

    init(stateDirectory: URL? = nil) {
        self.stateDirectory = stateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JustWisper/SyncState", isDirectory: true)
    }

    func inspect(folder: URL) throws -> Snapshot? {
        let url = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { observed[url.path] = "missing"; return nil }
        let data = try boundedData(url)
        let snapshot = try decode(data)
        observed[url.path] = digest(data)
        return snapshot
    }

    func push(_ state: LibraryState, folder: URL) throws -> PushResult {
        // Reject oversized local state before invoking a file provider. The final
        // snapshot is checked again after attaching its existing parent revision.
        let preparedSnapshot = try makeSnapshot(state, parent: nil)
        _ = try snapshotData(preparedSnapshot)
        let url = folder.appendingPathComponent(filename)
        return try coordinatedWrite(url) { coordinatedURL in
            let existing = FileManager.default.fileExists(atPath: coordinatedURL.path) ? try boundedData(coordinatedURL) : nil
            let actual = existing.map(digest) ?? "missing"
            guard let expected = observed[url.path], expected == actual else {
                return .conflict(try saveConflict(state, folder: folder))
            }
            let parent = try existing.map(decode)?.revisionID
            var snapshot = preparedSnapshot
            snapshot.parentRevisionID = parent
            let output = try snapshotData(snapshot)
            // Immutable revision files retain both sides of an eventual cross-Mac
            // race, even if a file-sync provider chooses one canonical file.
            if let revisionID = snapshot.revisionID {
                try output.write(to: revisionURL(revisionID, folder: folder), options: .atomic)
            }
            if let existing {
                let backup = folder.appendingPathComponent("JustWisper-previous-\(UUID().uuidString).json")
                try existing.write(to: backup, options: .atomic)
            }
            try output.write(to: coordinatedURL, options: .atomic)
            observed[url.path] = digest(output)
            return .saved
        }
    }

    func pull(folder: URL) throws -> LibraryState {
        guard let snapshot = try inspect(folder: folder) else { throw AppError.message("This folder has no published JustWisper configuration. Publish this Mac's settings first.") }
        return snapshot.configuration
    }

    /// Enabling requires a deliberate initial source. Resume uses only a previously
    /// saved per-folder baseline; it never silently chooses a winner on first use.
    func startAutomatic(folder: URL, initialChoice: InitialChoice,
                        localState: @escaping () -> LibraryState,
                        applyRemote: @escaping (LibraryState) throws -> Void,
                        onStatus: @escaping (String) -> Void) throws {
        stopAutomatic()
        let baseline: Baseline
        switch initialChoice {
        case .resume:
            guard let saved = try loadBaseline(folder: folder) else {
                throw AppError.message("Choose whether this Mac or the shared configuration should initialize automatic sync.")
            }
            baseline = saved
            observed[folder.appendingPathComponent(filename).path] = saved.remoteHash
        case .useLocal:
            _ = try inspect(folder: folder)
            switch try push(localState(), folder: folder) {
            case .saved: break
            case .conflict(let copy): throw AppError.message("The shared configuration changed while enabling sync. Local copy preserved at \(copy.path). Review the folder and choose an initial source again.")
            }
            baseline = try currentBaseline(folder: folder, local: localState())
        case .useShared:
            guard let snapshot = try inspect(folder: folder) else { throw AppError.message("Publish a configuration to this folder before choosing the shared source.") }
            try applyRemote(Self.mergingShared(snapshot.configuration, with: localState()))
            baseline = try currentBaseline(folder: folder, local: localState())
        }
        try saveBaseline(baseline, folder: folder)
        automatic = AutomaticSession(folder: folder, baseline: baseline, localState: localState, applyRemote: applyRemote, onStatus: onStatus)
        automaticRunning = true
        status("Automatic configuration sync is on")
        pollAutomatic()
        guard automaticRunning else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAutomatic() }
        }
    }

    func stopAutomatic() {
        timer?.invalidate(); timer = nil
        automatic = nil
        automaticRunning = false
        lastStatus = nil
    }

    /// Deterministic polling entry point also used by tests. Changes converge when
    /// one side changed; conflicting or divergent revisions preserve both sides.
    func pollAutomatic() {
        guard var session = automatic else { return }
        do {
            let local = session.localState()
            let localHash = try configurationHash(local)
            let remoteURL = session.folder.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: remoteURL.path) else {
                status("Automatic sync is waiting: the shared file is missing. Choose an initial source to restore it.")
                return
            }
            let remoteData = try boundedData(remoteURL)
            let remoteHash = digest(remoteData)
            let localChanged = localHash != session.baseline.localHash
            let remoteChanged = remoteHash != session.baseline.remoteHash
            guard localChanged || remoteChanged else { return }
            let remote = try decode(remoteData)
            let remoteConfigurationHash = try configurationHash(remote.configuration)
            if localHash == remoteConfigurationHash {
                session.baseline = Baseline(localHash: localHash, remoteHash: remoteHash, revisionID: remote.revisionID)
            } else if localChanged && remoteChanged {
                try pauseForConflict(local, session: session)
                return
            } else if remoteChanged {
                if let previousRevision = session.baseline.revisionID,
                   !isDescendant(remote, of: previousRevision, folder: session.folder) {
                    try pauseForConflict(local, session: session)
                    return
                }
                // The callback backs up and atomically saves through the sole app
                // writer. It may throw while recording; no baseline advances then.
                try session.applyRemote(Self.mergingShared(remote.configuration, with: local))
                session.baseline = Baseline(localHash: try configurationHash(session.localState()), remoteHash: remoteHash, revisionID: remote.revisionID)
                status("Shared configuration applied automatically")
            } else {
                observed[remoteURL.path] = session.baseline.remoteHash
                switch try push(local, folder: session.folder) {
                case .saved:
                    session.baseline = try currentBaseline(folder: session.folder, local: session.localState())
                    status("Configuration published automatically")
                case .conflict(let copy):
                    let notify = session.onStatus
                    stopAutomatic()
                    notify("Automatic sync paused: shared settings changed. Local configuration preserved as \(copy.lastPathComponent). Choose an initial source to resume.")
                    return
                }
            }
            observed[remoteURL.path] = session.baseline.remoteHash
            try saveBaseline(session.baseline, folder: session.folder)
            automatic = session
        } catch { status("Automatic sync is waiting: \(error.localizedDescription)") }
    }

    static func mergingShared(_ shared: LibraryState, with local: LibraryState) -> LibraryState {
        var result = shared
        result.history = local.history
        let settings = local.settings
        result.settings.configSyncFolder = settings.configSyncFolder
        result.settings.autoSyncConfiguration = settings.autoSyncConfiguration
        result.settings.launchAtLogin = settings.launchAtLogin
        result.settings.captureFocusedText = settings.captureFocusedText
        result.settings.captureSelectedText = settings.captureSelectedText
        result.settings.captureRecentClipboard = settings.captureRecentClipboard
        result.settings.mouseRecordingButton = settings.mouseRecordingButton
        result.settings.mouseRecordingBehavior = settings.mouseRecordingBehavior
        result.settings.modeSwitcherShortcut = settings.modeSwitcherShortcut
        result.settings.automationEnabled = settings.automationEnabled
        result.settings.learnCorrections = settings.learnCorrections
        result.settings.retainAudio = settings.retainAudio
        result.settings.retentionDays = settings.retentionDays
        result.settings.meetingSource = settings.meetingSource
        result.settings.enableSpeakerSeparation = settings.enableSpeakerSeparation
        result.settings.localExecutable = settings.localExecutable
        result.settings.localModel = settings.localModel
        result.settings.inputDeviceUID = settings.inputDeviceUID
        for index in result.modes.indices {
            result.modes[index].localModelOverride = local.modes.first { $0.id == result.modes[index].id }?.localModelOverride ?? ""
        }
        return result
    }

    private func portable(_ state: LibraryState) -> LibraryState {
        var result = state
        result.history = []
        result.settings.configSyncFolder = ""
        result.settings.autoSyncConfiguration = false
        result.settings.launchAtLogin = false
        result.settings.captureFocusedText = false
        result.settings.captureSelectedText = false
        result.settings.captureRecentClipboard = false
        result.settings.mouseRecordingButton = nil
        result.settings.mouseRecordingBehavior = .toggle
        result.settings.modeSwitcherShortcut = nil
        result.settings.automationEnabled = false
        result.settings.learnCorrections = false
        result.settings.retainAudio = false
        result.settings.retentionDays = 30
        result.settings.meetingSource = .mixed
        result.settings.enableSpeakerSeparation = false
        result.settings.localExecutable = ""
        result.settings.localModel = ""
        result.settings.inputDeviceUID = ""
        for index in result.modes.indices { result.modes[index].localModelOverride = "" }
        return result
    }

    private func configurationHash(_ state: LibraryState) throws -> String { digest(try encoded(portable(state))) }
    private func makeSnapshot(_ state: LibraryState, parent: UUID?) throws -> Snapshot {
        let configuration = portable(state)
        return Snapshot(revisionID: UUID(), parentRevisionID: parent, configurationHash: try configurationHash(configuration), configuration: configuration)
    }
    private func currentBaseline(folder: URL, local: LibraryState) throws -> Baseline {
        let url = folder.appendingPathComponent(filename)
        let data = try boundedData(url)
        // Never acknowledge bytes that arrived after our inspect/write: the
        // applied or published state belongs to the exact observed revision.
        guard observed[url.path] == digest(data) else {
            throw AppError.message("The shared configuration changed while syncing. Retry after the folder finishes syncing.")
        }
        return Baseline(localHash: try configurationHash(local), remoteHash: digest(data), revisionID: try decode(data).revisionID)
    }
    private func pauseForConflict(_ local: LibraryState, session: AutomaticSession) throws {
        let copy = try saveConflict(local, folder: session.folder)
        let notify = session.onStatus
        stopAutomatic()
        notify("Automatic sync paused: both configurations changed or revisions diverged. Local configuration preserved as \(copy.lastPathComponent); the shared file was preserved. Choose an initial source to resume.")
    }
    private func saveConflict(_ state: LibraryState, folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("JustWisper-local-conflict-\(UUID().uuidString).json")
        try snapshotData(makeSnapshot(state, parent: nil)).write(to: url, options: .atomic)
        return url
    }
    private func isDescendant(_ snapshot: Snapshot, of ancestor: UUID, folder: URL) -> Bool {
        var candidate = snapshot
        var visited: Set<UUID> = []
        for _ in 0..<64 {
            if candidate.revisionID == ancestor { return true }
            guard let parent = candidate.parentRevisionID, visited.insert(parent).inserted else { return false }
            if parent == ancestor { return true }
            guard let data = try? boundedData(revisionURL(parent, folder: folder)), let previous = try? decode(data), previous.revisionID == parent else { return false }
            candidate = previous
        }
        return false
    }
    private func revisionURL(_ id: UUID, folder: URL) -> URL { folder.appendingPathComponent("JustWisper-revision-\(id.uuidString).json") }
    private func baselineURL(folder: URL) -> URL { stateDirectory.appendingPathComponent(digest(Data(folder.standardizedFileURL.path.utf8))).appendingPathExtension("json") }
    private func loadBaseline(folder: URL) throws -> Baseline? {
        let url = baselineURL(folder: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Baseline.self, from: boundedData(url))
    }
    private func saveBaseline(_ baseline: Baseline, folder: URL) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: stateDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw AppError.message("The local sync state must be a real directory.") }
        let url = baselineURL(folder: folder)
        try encoded(baseline).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func status(_ message: String) {
        guard lastStatus != message else { return }
        lastStatus = message
        automatic?.onStatus(message)
    }
    private func boundedData(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size <= 5_000_000 else {
            throw AppError.message("Configuration files must be regular files no larger than 5 MB.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 5_000_000 else { throw AppError.message("The configuration file exceeds the 5 MB safety limit.") }
        return data
    }
    private func decode(_ data: Data) throws -> Snapshot {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard [1, 2].contains(snapshot.formatVersion) else { throw AppError.message("This configuration uses a newer format. Update JustWisper before pulling it.") }
        guard !snapshot.configuration.modes.isEmpty else { throw AppError.message("The shared configuration has no modes.") }
        if let expected = snapshot.configurationHash, expected != (try configurationHash(snapshot.configuration)) {
            throw AppError.message("The shared configuration hash does not match. Restore a preserved revision or publish it again.")
        }
        return snapshot
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    private func snapshotData(_ snapshot: Snapshot) throws -> Data {
        let data = try encoded(snapshot)
        guard data.count <= 5_000_000 else { throw AppError.message("The configuration exceeds the 5 MB sync limit. Reduce large snippets or instructions before publishing.") }
        return data
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func coordinatedWrite<T>(_ url: URL, operation: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        // A first publication creates the file. `.forReplacing` asks providers to
        // prepare an existing item for replacement and can fail for an absent URL.
        let options: NSFileCoordinator.WritingOptions = FileManager.default.fileExists(atPath: url.path) ? .forReplacing : []
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinatedURL in
            result = Result { try operation(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw AppError.message("The shared file could not be coordinated.") }
        return try result.get()
    }
}
