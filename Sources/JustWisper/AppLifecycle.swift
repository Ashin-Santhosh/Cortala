import AppKit

/// Coordinates asynchronous shutdown without depending on a running application.
@MainActor final class TerminationCoordinator {
    enum Decision { case terminateNow, terminateLater, terminateCancel }
    private enum State { case idle, cleaning, timedOut, ready }
    private var state: State = .idle
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private let cleanup: @MainActor () async throws -> Void
    private let waitForDeadline: @MainActor () async throws -> Void
    private let reply: @MainActor (Bool) -> Void

    init(cleanup: @escaping @MainActor () async throws -> Void,
         waitForDeadline: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(15)) },
         reply: @escaping @MainActor (Bool) -> Void) {
        self.cleanup = cleanup
        self.waitForDeadline = waitForDeadline
        self.reply = reply
    }

    func requestTermination() -> Decision {
        switch state {
        case .ready: return .terminateNow
        case .cleaning: return .terminateLater
        case .timedOut: return .terminateCancel
        case .idle: break
        }
        state = .cleaning
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await cleanup()
                finish(success: true)
            } catch {
                finish(success: false)
            }
        }
        deadlineTask = Task { [weak self] in
            guard let self else { return }
            do { try await waitForDeadline() } catch { return }
            guard state == .cleaning else { return }
            state = .timedOut
            deadlineTask = nil
            // Cancel the quit request, but let audio preservation finish safely.
            reply(false)
        }
        return .terminateLater
    }

    private func finish(success: Bool) {
        let needsReply = state == .cleaning
        state = success ? .ready : .idle
        deadlineTask?.cancel()
        deadlineTask = nil
        cleanupTask = nil
        if needsReply { reply(success) }
    }
}

@MainActor final class AppLifecycle: NSObject, NSApplicationDelegate {
    private var store: AppStore?
    private lazy var termination = TerminationCoordinator(
        cleanup: { [weak self] in await self?.store?.prepareForTermination() },
        reply: { NSApp.reply(toApplicationShouldTerminate: $0) }
    )

    func configure(store: AppStore) { self.store = store }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch termination.requestTermination() {
        case .terminateNow: return .terminateNow
        case .terminateLater: return .terminateLater
        case .terminateCancel: return .terminateCancel
        }
    }
}
