import Foundation
import Testing
@testable import JustWisper

struct LocalRuntimeSecurityTests {
    @Test func inheritedLoaderOverridesCannotChangeSelectedRuntime() {
        let environment = LocalProcessEnvironment.sanitized([
            "PATH": "/tmp/untrusted", "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
            "DYLD_LIBRARY_PATH": "/tmp", "GGML_BACKEND_PATH": "/tmp/backend.so",
            "GGML_BACKEND_DL_PATH": "/tmp", "LD_PRELOAD": "/tmp/inject.so",
            "LD_LIBRARY_PATH": "/tmp", "HOME": "/Users/test", "LANG": "en_US.UTF-8"
        ])
        #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(!environment.keys.contains { $0.hasPrefix("DYLD_") || $0.hasPrefix("GGML_") || $0.hasPrefix("LD_") })
    }

    @Test func oversizedModelDownloadIsCancelledBeforeInstallation() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // Suspended tasks never issue a network request.
        let oversized = session.downloadTask(with: URL(string: "https://example.invalid/model")!)
        let delegate = ModelDownloadDelegate(maximumBytes: 100) { _ in }
        delegate.urlSession(session, downloadTask: oversized, didWriteData: 101,
                            totalBytesWritten: 101, totalBytesExpectedToWrite: NSURLSessionTransferSizeUnknown)
        #expect(oversized.state == .canceling || oversized.state == .completed)
        let announced = session.downloadTask(with: URL(string: "https://example.invalid/model")!)
        delegate.urlSession(session, downloadTask: announced, didWriteData: 1,
                            totalBytesWritten: 1, totalBytesExpectedToWrite: 101)
        #expect(announced.state == .canceling || announced.state == .completed)
    }
}
