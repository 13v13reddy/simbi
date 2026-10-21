import Foundation
import Testing

@testable import CodexKit

@Suite("Transcript fixer lifecycle")
struct TranscriptFixerTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "simbi-fixer-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }

    @Test("new cues cannot overlap a pass while its snapshot is being prepared")
    func serializesSnapshot() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = FixerServer()
        let gate = FixerGate()
        let host = FixerHost(snapshotGate: gate)
        let events = FixerEvents()
        let fixer = TranscriptFixer(noteFolderURL: folder, server: server, savedThreadId: "fixer")
        await fixer.setHost(host)
        await fixer.setEventSink { events.append($0) }
        try await fixer.recordingStarted()
        let first = Task { await fixer.cueAppended(index: 1) }
        try await waitUntil { await host.snapshots == 1 }
        #expect(events.values == [.passStarted])
        await fixer.cueAppended(index: 2)
        #expect(await host.snapshots == 1)
        #expect(await server.turnInputs.isEmpty)
        await gate.release()
        await first.value
        #expect(await server.turnInputs.count == 1)
        await server.complete(turn: 1)
        try await waitUntil { await server.turnInputs.count == 2 }
        await fixer.recordingStopped()
        await server.complete(turn: 2)
    }

    @Test("a pass finishes merging before a new cue can refresh its snapshot")
    func serializesMerge() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = FixerServer()
        let gate = FixerGate()
        let host = FixerHost(mergeGate: gate)
        let fixer = TranscriptFixer(noteFolderURL: folder, server: server, savedThreadId: "fixer")
        await fixer.setHost(host)
        try await fixer.recordingStarted()
        await fixer.cueAppended(index: 1)
        await server.complete(turn: 1)
        try await waitUntil { await host.merges == 1 }
        await fixer.cueAppended(index: 2)
        #expect(await host.snapshots == 1)
        #expect(await server.turnInputs.count == 1)
        await gate.release()
        try await waitUntil { await server.turnInputs.count == 2 }
        await fixer.recordingStopped()
        await server.complete(turn: 2)
    }

    @Test("Stop retries cues whose turn failed to start")
    func retriesRejectedCues() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = FixerServer(rejectedStarts: 1)
        let fixer = TranscriptFixer(noteFolderURL: folder, server: server, savedThreadId: "fixer")
        try await fixer.recordingStarted()
        await fixer.cueAppended(index: 4)
        #expect(await server.turnInputs.count == 1)
        await fixer.recordingStopped()
        let inputs = await server.turnInputs
        #expect(inputs.count == 2)
        #expect(inputs.last?.contains("Cues 1..4 are new") == true)
        await server.complete(turn: 2)
    }

    @Test(
        "an unsuccessful turn keeps its cues pending and never merges partial edits",
        arguments: ["failed", "interrupted"])
    func retriesFailedTurn(status: String) async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = FixerServer()
        let host = FixerHost()
        let events = FixerEvents()
        let fixer = TranscriptFixer(noteFolderURL: folder, server: server, savedThreadId: "fixer")
        await fixer.setHost(host)
        await fixer.setEventSink { events.append($0) }
        try await fixer.recordingStarted()
        await fixer.cueAppended(index: 1)
        await fixer.recordingStopped()
        await server.complete(turn: 1, status: status)
        try await waitUntil { events.values.count >= 2 }
        #expect(await host.merges == 0)
        #expect(!events.values.contains(.done))
        await fixer.recordingStopped()
        #expect(await server.turnInputs.count == 2)
        await server.complete(turn: 2)
        try await waitUntil { events.values.contains(.done) }
    }

    @Test("a rejected final pass ends the import wait without claiming all cues were reviewed")
    func signalsStoppedFailure() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = FixerServer(rejectedTurns: [2])
        let events = FixerEvents()
        let fixer = TranscriptFixer(noteFolderURL: folder, server: server, savedThreadId: nil)
        await fixer.setEventSink { events.append($0) }
        try await fixer.recordingStarted()
        await fixer.cueAppended(index: 3)
        await fixer.recordingStopped()
        // The opening instructions finish; the coalesced cue pass is rejected.
        await server.complete(turn: 1)
        try await waitUntil { events.values.contains(.stoppedAfterFailure) }
        #expect(!events.values.contains(.done))
        #expect(events.values.last == .stoppedAfterFailure)
        #expect(await server.turnInputs.count == 2)
    }

    @Test("completion before the start response is merged once after its turn id is confirmed")
    func buffersEarlyCompletion() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = FixerGate()
        let server = FixerServer(replyGate: gate)
        let host = FixerHost()
        let events = FixerEvents()
        let fixer = TranscriptFixer(noteFolderURL: folder, server: server, savedThreadId: "fixer")
        await fixer.setHost(host)
        await fixer.setEventSink { events.append($0) }
        try await fixer.recordingStarted()
        let starting = Task { await fixer.cueAppended(index: 1) }
        try await waitUntil { await server.turnInputs.count == 1 }
        await server.complete(turn: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await host.merges == 0)
        await gate.release()
        await starting.value
        await fixer.recordingStopped()
        try await waitUntil { events.values.contains(.done) }
        #expect(await host.merges == 1)
        #expect(events.values.filter { $0 == .passCompleted }.count == 1)
    }

    @Test("another turn's completion cannot finish the active fixer pass")
    func ignoresUnrelatedCompletion() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = FixerServer()
        let host = FixerHost()
        let events = FixerEvents()
        let fixer = TranscriptFixer(noteFolderURL: folder, server: server, savedThreadId: "fixer")
        await fixer.setHost(host)
        await fixer.setEventSink { events.append($0) }
        try await fixer.recordingStarted()
        await fixer.cueAppended(index: 1)
        await fixer.recordingStopped()
        await server.complete(turn: 99)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await host.merges == 0)
        #expect(events.values == [.passStarted])
        await server.complete(turn: 1)
        try await waitUntil { events.values.contains(.done) }
        #expect(await host.merges == 1)
    }

    @Test("duplicate completion cannot merge the same snapshot twice")
    func ignoresDuplicateCompletion() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = FixerServer()
        let gate = FixerGate()
        let host = FixerHost(mergeGate: gate)
        let events = FixerEvents()
        let fixer = TranscriptFixer(noteFolderURL: folder, server: server, savedThreadId: "fixer")
        await fixer.setHost(host)
        await fixer.setEventSink { events.append($0) }
        try await fixer.recordingStarted()
        await fixer.cueAppended(index: 1)
        await fixer.recordingStopped()
        await server.complete(turn: 1)
        try await waitUntil { await host.merges == 1 }
        await server.complete(turn: 1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await host.merges == 1)
        await gate.release()
        try await waitUntil { events.values.contains(.done) }
        #expect(events.values.filter { $0 == .passCompleted }.count == 1)
    }
}

private final class FixerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FixerEvent] = []
    var values: [FixerEvent] { lock.withLock { events } }
    func append(_ event: FixerEvent) { lock.withLock { events.append(event) } }
}

private actor FixerGate {
    private var open = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        open = true
        waiting?.resume()
        waiting = nil
    }
}

private actor FixerHost: TranscriptFixerHost {
    private let snapshotGate: FixerGate?
    private let mergeGate: FixerGate?
    private(set) var snapshots = 0
    private(set) var merges = 0
    init(snapshotGate: FixerGate? = nil, mergeGate: FixerGate? = nil) {
        self.snapshotGate = snapshotGate
        self.mergeGate = mergeGate
    }
    func fixerWillStartPass() async {
        snapshots += 1
        if snapshots == 1 { await snapshotGate?.wait() }
    }
    func fixerDidCompletePass() async -> Int {
        merges += 1
        if merges == 1 { await mergeGate?.wait() }
        return 1
    }
}

private actor FixerServer: TranscriptFixerServing {
    private var handlers: [@Sendable (String, Data) -> Void] = []
    private var rejectedStarts: Int
    private let rejectedTurns: Set<Int>
    private let replyGate: FixerGate?
    private(set) var turnInputs: [String] = []
    init(rejectedStarts: Int = 0, rejectedTurns: Set<Int> = [], replyGate: FixerGate? = nil) {
        self.rejectedStarts = rejectedStarts
        self.rejectedTurns = rejectedTurns
        self.replyGate = replyGate
    }
    func addNotificationHandler(_ handler: @escaping @Sendable (String, Data) -> Void) {
        handlers.append(handler)
    }
    func startFixerThread(cwd: URL, name: String) -> String { "fixer" }
    func request(method: String, params: [String: any Sendable]) async throws -> Data {
        if method != "turn/start" { return Data("{}".utf8) }
        let input = params["input"] as? [[String: any Sendable]]
        turnInputs.append(input?.first?["text"] as? String ?? "")
        let turn = turnInputs.count
        if rejectedStarts > 0 {
            rejectedStarts -= 1
            throw AppServerClient.ClientError.serverError(code: -1, message: "test rejection")
        }
        if rejectedTurns.contains(turn) {
            throw AppServerClient.ClientError.serverError(code: -1, message: "test rejection")
        }
        if turn == 1 { await replyGate?.wait() }
        return Data("{\"turn\":{\"id\":\"turn-\(turn)\"}}".utf8)
    }
    func complete(turn: Int, status: String = "completed") {
        let data = try! JSONSerialization.data(withJSONObject: [
            "threadId": "fixer", "turn": ["id": "turn-\(turn)", "status": status],
        ])
        for handler in handlers { handler("turn/completed", data) }
    }
}
