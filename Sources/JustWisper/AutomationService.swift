import Darwin
import Foundation
import SwiftUI

struct AutomationCommand: Codable {
    var id: UUID
    var createdAt: Double
    var action: String
    var arguments: [String: String]
}

struct AutomationReply: Codable {
    var ok: Bool
    var error: String?
    var result: [String: String]?

    static func success(_ result: [String: String] = [:]) -> Self { .init(ok: true, error: nil, result: result) }
    static func failure(_ message: String) -> Self { .init(ok: false, error: message, result: nil) }
}

/// Explicitly enabled same-user local requests. The running app remains the sole library writer.
@MainActor
final class AutomationService: ObservableObject {
    static let allowedActions: Set<String> = ["select_mode", "start_recording", "stop_recording", "toggle_recording", "cancel", "add_vocabulary", "remove_vocabulary", "add_snippet", "remove_snippet"]
    @Published private(set) var error: String?
    private let directory: URL
    private var inbox: URL { directory.appendingPathComponent("inbox", isDirectory: true) }
    private var replies: URL { directory.appendingPathComponent("replies", isDirectory: true) }
    private var status: URL { directory.appendingPathComponent("status.json") }
    private var timer: Timer?
    private var handler: ((AutomationCommand) -> AutomationReply)?

    init(root: URL) { directory = root.appendingPathComponent("Automation", isDirectory: true) }

    func start(handler: @escaping (AutomationCommand) -> AutomationReply) {
        stop()
        do {
            for folder in [directory, inbox, replies] { try prepare(folder) }
            self.handler = handler
            error = nil
            poll()
            timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } catch { self.error = "Local automation could not start: \(error.localizedDescription)" }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
        // Remove only a private regular status file owned by this process's user.
        if Self.readPrivateFile(status, maximumBytes: 4096) != nil { try? FileManager.default.removeItem(at: status) }
    }

    func poll(now: Date = Date()) {
        guard let handler else { return }
        do {
            try write(["pid": Double(ProcessInfo.processInfo.processIdentifier), "updatedAt": now.timeIntervalSince1970], to: status)
            let pending = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var handled = 0
            for url in pending {
                guard handled < 20 else { break }
                guard url.pathExtension == "json", let filenameID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      let data = Self.readPrivateFile(url, maximumBytes: 65_536) else { continue }
                handled += 1
                let reply: AutomationReply
                if let command = try? JSONDecoder().decode(AutomationCommand.self, from: data), command.id == filenameID {
                    let age = now.timeIntervalSince1970 - command.createdAt
                    if age < -5 || age > 30 { reply = .failure("The automation request expired. Retry while JustWisper is running.") }
                    else if !Self.allowedActions.contains(command.action) { reply = .failure("Unsupported local automation action.") }
                    else { reply = handler(command) }
                } else { reply = .failure("Invalid automation request.") }
                let destination = replies.appendingPathComponent(filenameID.uuidString.lowercased()).appendingPathExtension("json")
                try write(reply, to: destination)
                try FileManager.default.removeItem(at: url)
            }
            for url in try FileManager.default.contentsOfDirectory(at: replies, includingPropertiesForKeys: [.contentModificationDateKey]) {
                guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let changed = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      now.timeIntervalSince(changed) > 120, Self.readPrivateFile(url, maximumBytes: 65_536) != nil else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        } catch { self.error = "Local automation: \(error.localizedDescription)" }
    }

    private func prepare(_ folder: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path) {
            let attributes = try manager.attributesOfItem(atPath: folder.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw ProviderError.message("The automation directory must be a real directory owned by the current user.")
            }
        } else { try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    nonisolated static func readPrivateFile(_ url: URL, maximumBytes: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_uid == getuid(),
              information.st_mode & S_IFMT == S_IFREG, information.st_mode & 0o077 == 0,
              information.st_size >= 0, information.st_size <= maximumBytes else { return nil }
        return try? handle.readToEnd()
    }
}
