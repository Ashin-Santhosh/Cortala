import Foundation

/// Device-local storage preferences and exact ownership of app-created recordings.
/// Folder selection never makes unrelated files eligible for retention/deletion.
final class RecordingStorage {
    private struct State: Codable {
        var meetingDirectory: String?
        var managedFiles: Set<String> = []
    }
    let defaultDirectory: URL
    private let stateURL: URL
    private var state = State()
    private var loadError: Error?
    private(set) var warning: String?
    var meetingDirectory: URL { state.meetingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory }
    var usesDefaultMeetingDirectory: Bool { state.meetingDirectory == nil }

    init(root: URL) {
        defaultDirectory = root.appendingPathComponent("Recordings", isDirectory: true)
        stateURL = root.appendingPathComponent("recording-storage.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL)) }
            catch { loadError = error }
        }
    }

    func selectMeetingDirectory(_ directory: URL?) throws {
        if let loadError { throw AppError.message("Recording folder preferences could not be read; the original file is preserved. \(loadError.localizedDescription)") }
        if let directory {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true, FileManager.default.isWritableFile(atPath: directory.path) else {
                throw AppError.message("Choose a writable folder for meeting recordings.")
            }
        }
        var next = state
        next.meetingDirectory = directory?.standardizedFileURL.path
        try persist(next)
        state = next
    }

    func destination(isMeeting: Bool, extension fileExtension: String) throws -> URL {
        warning = nil
        var directory = isMeeting ? meetingDirectory : defaultDirectory
        if loadError != nil {
            directory = defaultDirectory
            warning = "Folder preferences are unreadable. This recording is preserved in the default folder; the original preferences file was kept."
        } else if directory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory != true || !FileManager.default.isWritableFile(atPath: directory.path) {
                directory = defaultDirectory
                warning = "Your chosen meeting folder is unavailable. This recording is saved in the default folder. Reconnect the drive or choose another folder."
            }
        }
        if directory.standardizedFileURL == defaultDirectory.standardizedFileURL {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let suffix = fileExtension.isEmpty ? "wav" : fileExtension
        guard suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw AppError.message("Unsupported recording file extension.") }
        let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suffix)
        if directory.standardizedFileURL != defaultDirectory.standardizedFileURL {
            var next = state
            next.managedFiles.insert(destination.standardizedFileURL.path)
            try persist(next)
            state = next
        }
        return destination
    }

    func isManaged(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent() == defaultDirectory.standardizedFileURL || state.managedFiles.contains(url.standardizedFileURL.path)
    }
    func forget(_ url: URL) {
        guard state.managedFiles.contains(url.standardizedFileURL.path) else { return }
        var next = state
        next.managedFiles.remove(url.standardizedFileURL.path)
        if (try? persist(next)) != nil { state = next }
    }
    private func persist(_ next: State) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}
