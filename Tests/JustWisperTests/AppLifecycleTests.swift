import Foundation
import Testing
@testable import JustWisper

struct AppLifecycleTests {
    @Test @MainActor func concurrentQuitRequestsWaitForOneCleanupAndReplyOnce() async {
        let (started, start) = AsyncStream.makeStream(of: Void.self)
        let (release, finish) = AsyncStream.makeStream(of: Void.self)
        let (replies, reply) = AsyncStream.makeStream(of: Bool.self)
        var starts = 0, replyCount = 0
        let coordinator = TerminationCoordinator(cleanup: {
            starts += 1
            start.yield()
            for await _ in release { break }
        }, reply: { result in replyCount += 1; reply.yield(result) })

        #expect(coordinator.requestTermination() == .terminateLater)
        #expect(coordinator.requestTermination() == .terminateLater)
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        #expect(starts == 1)
        #expect(replyCount == 0)
        finish.yield()
        var replyIterator = replies.makeAsyncIterator()
        #expect(await replyIterator.next() == true)
        #expect(coordinator.requestTermination() == .terminateNow)
        #expect(starts == 1)
        #expect(replyCount == 1)
    }

    @Test @MainActor func cleanupFailureCancelsQuitAndAllowsRetry() async {
        struct CleanupFailure: Error {}
        let (replies, reply) = AsyncStream.makeStream(of: Bool.self)
        var attempts = 0
        let coordinator = TerminationCoordinator(cleanup: {
            attempts += 1
            if attempts == 1 { throw CleanupFailure() }
        }, reply: { reply.yield($0) })
        var replyIterator = replies.makeAsyncIterator()

        #expect(coordinator.requestTermination() == .terminateLater)
        #expect(await replyIterator.next() == false)
        #expect(coordinator.requestTermination() == .terminateLater)
        #expect(await replyIterator.next() == true)
        #expect(coordinator.requestTermination() == .terminateNow)
        #expect(attempts == 2)
    }

    @Test @MainActor func deadlineCancelsQuitWithoutCancellingAudioPreservation() async {
        let (release, finish) = AsyncStream.makeStream(of: Void.self)
        let (deadlines, deadline) = AsyncStream.makeStream(of: Void.self)
        let (replies, reply) = AsyncStream.makeStream(of: Bool.self)
        let (completed, complete) = AsyncStream.makeStream(of: Void.self)
        var replyCount = 0
        var cleanupCancelled = false
        let coordinator = TerminationCoordinator(cleanup: {
            for await _ in release { break }
            cleanupCancelled = Task.isCancelled
            complete.yield()
        }, waitForDeadline: {
            for await _ in deadlines { break }
        }, reply: { result in replyCount += 1; reply.yield(result) })

        #expect(coordinator.requestTermination() == .terminateLater)
        deadline.yield()
        var replyIterator = replies.makeAsyncIterator()
        #expect(await replyIterator.next() == false)
        #expect(coordinator.requestTermination() == .terminateCancel)
        finish.yield()
        var completedIterator = completed.makeAsyncIterator()
        _ = await completedIterator.next()
        // Let the cleanup task finish after its final asynchronous suspension.
        for _ in 0..<100 {
            if coordinator.requestTermination() == .terminateNow { break }
            await Task.yield()
        }
        #expect(coordinator.requestTermination() == .terminateNow)
        #expect(!cleanupCancelled)
        #expect(replyCount == 1)
    }
}
