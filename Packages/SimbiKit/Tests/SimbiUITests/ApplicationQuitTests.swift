import AppKit
import Foundation
import Testing

@testable import SimbiUI

@Suite("Safe application quit")
@MainActor
struct ApplicationQuitTests {
    @Test("Quit defers and coalesces requests until local saving completes")
    func waitsForSaving() async throws {
        var release = false
        var preparations = 0
        var replies: [Bool] = []
        let coordinator = ApplicationQuitCoordinator(
            prepare: {
                preparations += 1
                while !release { try? await Task.sleep(for: .milliseconds(10)) }
                return true
            }, didFail: { Issue.record("Quit should succeed") })
        #expect(coordinator.requestTermination { replies.append($0) } == .terminateLater)
        #expect(coordinator.requestTermination { _ in Issue.record("Duplicate reply") } == .terminateLater)
        try await Task.sleep(for: .milliseconds(40))
        #expect(coordinator.isQuitting)
        #expect(replies.isEmpty)
        #expect(preparations == 1)
        release = true
        for _ in 0..<100 where replies.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(replies == [true])
    }

    @Test("a failed or stuck save cancels Quit visibly", arguments: [false, true])
    func cancelsUnsafeQuit(stuck: Bool) async throws {
        var release = false
        var replies: [Bool] = []
        var reported = false
        let coordinator = ApplicationQuitCoordinator(
            timeout: 0.08,
            prepare: {
                while stuck && !release { try? await Task.sleep(for: .milliseconds(10)) }
                return false
            }, didFail: { reported = true })
        #expect(coordinator.requestTermination { replies.append($0) } == .terminateLater)
        for _ in 0..<100 where replies.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(replies == [false])
        #expect(reported)
        #expect(!coordinator.isQuitting)
        release = true
    }
}
