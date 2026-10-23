import Foundation
import Testing
@testable import JustWisper

struct AutomationServiceTests {
    @Test @MainActor func requestsArePrivateExpiredAndProcessedByTheSingleAppWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AutomationService(root: root)
        defer { service.stop() }
        var received = [String]()
        service.start { command in received.append(command.action); return .success(["saved": "true"]) }
        let directory = root.appendingPathComponent("Automation")
        let id = UUID()
        let request = directory.appendingPathComponent("inbox/\(id.uuidString.lowercased()).json")
        let command = AutomationCommand(id: id, createdAt: Date().timeIntervalSince1970, action: "add_vocabulary", arguments: ["phrase": "JustWisper"])
        try JSONEncoder().encode(command).write(to: request)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: request.path)
        service.poll()
        #expect(received == ["add_vocabulary"])
        #expect(!FileManager.default.fileExists(atPath: request.path))
        let replyURL = directory.appendingPathComponent("replies/\(id.uuidString.lowercased()).json")
        let reply = try JSONDecoder().decode(AutomationReply.self, from: Data(contentsOf: replyURL))
        #expect(reply.ok)
        #expect(reply.result?["saved"] == "true")
        let oldID = UUID()
        let old = directory.appendingPathComponent("inbox/\(oldID.uuidString.lowercased()).json")
        try JSONEncoder().encode(AutomationCommand(id: oldID, createdAt: Date().timeIntervalSince1970 - 60, action: "start_recording", arguments: [:])).write(to: old)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: old.path)
        service.poll()
        #expect(received.count == 1)
        let expired = try JSONDecoder().decode(AutomationReply.self, from: Data(contentsOf: directory.appendingPathComponent("replies/\(oldID.uuidString.lowercased()).json")))
        #expect(!expired.ok)
        #expect(expired.error?.contains("expired") == true)
    }

    @Test func symlinksAndNonprivateFilesCannotBecomeRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("regular")
        try Data("request".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(AutomationService.readPrivateFile(file, maximumBytes: 100) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(AutomationService.readPrivateFile(file, maximumBytes: 100) != nil)
        #expect(AutomationService.readPrivateFile(file, maximumBytes: 2) == nil)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(AutomationService.readPrivateFile(link, maximumBytes: 100) == nil)
    }
}
