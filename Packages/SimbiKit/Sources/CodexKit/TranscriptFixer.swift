import Foundation
import SimbiKit

/// Host hooks around each fixer pass. The pipeline implements these: it
/// refreshes the fixer's worktree copy of the transcript before a turn and
/// merges the per-cue diff back into the live file after — so the live
/// transcript.vtt keeps exactly ONE writer and fixer passes can never race
/// (or corrupt) the pipeline's appends.
public protocol TranscriptFixerHost: AnyObject, Sendable {
    func fixerWillStartPass() async
    /// Returns the number of cue edits merged into the live transcript.
    @discardableResult
    func fixerDidCompletePass() async -> Int
}

/// The fixer's server boundary, kept small so request failures and notification
/// timing can be exercised without a live Codex process.
protocol TranscriptFixerServing: Sendable {
    func request(method: String, params: [String: any Sendable]) async throws -> Data
    func addNotificationHandler(_ handler: @escaping @Sendable (String, Data) -> Void) async
    func startFixerThread(cwd: URL, name: String) async throws -> String
}

extension AppServerClient: TranscriptFixerServing {
    func startFixerThread(cwd: URL, name: String) async throws -> String {
        try await CodexTurn.startThread(client: self, cwd: cwd, sandbox: "workspace-write", name: name)
    }
}

/// Coarse fixer activity for the UI (the header button's status):
/// one event per pass milestone, no payloads.
public enum FixerEvent: Equatable, Sendable {
    /// A pass began.
    case passStarted
    /// A pass ended; any edits were merged into the live transcript.
    case passCompleted
    /// Recording stopped and every cue has been reviewed.
    case done
    /// The request or turn failed; original transcript text remains intact.
    case passFailed
    /// Recording stopped with cues still awaiting a successful review.
    case stoppedAfterFailure
}

/// The per-note transcript-fixer thread (SPEC.md §5.2): a Codex worker
/// thread that fixes ASR errors in newly appended cues and unifies speaker
/// names. It works on a snapshot COPY of the transcript in
/// `.simbi/fixer-worktree/` (its task directory and sole writable root) with
/// plain apply_patch edits; the host diffs and merges each pass into the live
/// file (see `TranscriptFixerHost`). Its thread belongs to the shared Simbi
/// Codex project.
///
/// Ping policy: ping when ≥ 1 new cue has been appended since the last pass
/// AND the thread has no active turn; pings are coalesced. A final ping
/// fires at recording stop.
public actor TranscriptFixer {
    /// The fixer's task directory: holds its refreshed working copy of
    /// transcript.vtt, and nothing else.
    public static func worktreeURL(noteFolder: URL) -> URL {
        NoteLayout.fixerWorktreeURL(noteFolder: noteFolder)
    }

    /// Bumped whenever the thread's *contract* (worktree task directory, merge
    /// behavior, ping protocol) changes incompatibly. A note's saved
    /// thread carries the instructions it was created with, so threads
    /// from an older version are retired and recreated instead of
    /// resumed; the instruction *text* (user-editable FIXER.md) is
    /// tracked separately via `instructionsFingerprint`. History: 1 =
    /// snapshot-and-replay worktree, 2 = per-cue speaker-attribution fixes,
    /// 3 = shared Simbi Codex project with an explicit fixer task directory.
    public static let instructionsVersion = 3

    private let noteFolderURL: URL
    private let project: SimbiCodexProject
    private let client: any TranscriptFixerServing
    /// Model override for fixer turns (SPEC.md §5.5); nil = thread default.
    private let model: String?
    /// Reasoning-effort override; nil = the model's own default.
    private let effort: String?
    /// The thread's opening instructions — FIXER.md's resolved text,
    /// injected by the caller; defaults to the built-in prompt.
    private let instructions: String
    /// Persisted by the caller in .simbi/state.json across app restarts.
    public private(set) var threadId: String?
    /// A saved fixer from an older contract. It cannot be moved to the shared
    /// project, so archive it once before creating its replacement.
    private var retiredThreadId: String?

    /// Occupies the slot from snapshot preparation through the final merge.
    /// Actor isolation alone does not protect those asynchronous host calls.
    private struct Pass {
        enum Phase { case preparing, starting, running, merging }
        let throughCue: Int
        var phase: Phase = .preparing
        var turnId: String?
        var earlyCompletions: [String: String] = [:]
    }
    private var pass: Pass?
    private var lastReviewedCue = 0
    private var newestCue = 0
    private var stopping = false
    private var failed = false
    private var terminalNotified = false
    /// Weak: the pipeline owns the fixer; the back-reference must not keep
    /// either alive.
    private weak var host: (any TranscriptFixerHost)?
    /// Coarse status events for the header button; nil = nobody watching.
    private var eventSink: (@Sendable (FixerEvent) -> Void)?

    public init(
        noteFolderURL: URL, client: AppServerClient, savedThreadId: String?,
        retiredThreadId: String? = nil,
        model: String? = nil, effort: String? = nil,
        projectRootURL: URL = SimbiHome().rootURL,
        instructions: String = AgentInstructions.fixer.defaultContents
    ) {
        self.init(
            noteFolderURL: noteFolderURL, server: client, savedThreadId: savedThreadId,
            retiredThreadId: retiredThreadId, model: model, effort: effort,
            projectRootURL: projectRootURL, instructions: instructions)
    }

    init(
        noteFolderURL: URL, server: any TranscriptFixerServing, savedThreadId: String?,
        retiredThreadId: String? = nil,
        model: String? = nil, effort: String? = nil,
        projectRootURL: URL = SimbiHome().rootURL,
        instructions: String = AgentInstructions.fixer.defaultContents
    ) {
        self.noteFolderURL = noteFolderURL
        self.project = SimbiCodexProject(rootURL: projectRootURL)
        self.client = server
        self.threadId = savedThreadId
        self.retiredThreadId = retiredThreadId
        self.model = model
        self.effort = effort
        self.instructions = instructions
    }

    /// Persisted next to the thread id so a FIXER.md edit retires the
    /// saved thread (see `NoteRecordingState.fixerInstructionsHash`).
    public var instructionsFingerprint: String {
        AgentInstructions.fingerprint(instructions)
    }

    /// The pipeline registers itself as host before recording starts.
    public func setHost(_ host: any TranscriptFixerHost) {
        self.host = host
    }

    /// The UI registers a coarse activity feed before recording starts.
    public func setEventSink(_ sink: @escaping @Sendable (FixerEvent) -> Void) {
        self.eventSink = sink
    }

    private var bound = false

    /// Creates the fixer thread on first recording start, or unarchives +
    /// resumes the note's existing thread (archive → unarchive → resume).
    public func recordingStarted() async throws {
        stopping = false
        terminalNotified = false
        do {
            try await prepareThread()
        } catch {
            if !failed { failPass() }
            throw error
        }
    }

    private func prepareThread() async throws {
        // The task directory must exist before its first turn.
        do {
            try FileManager.default.createDirectory(
                at: Self.worktreeURL(noteFolder: noteFolderURL), withIntermediateDirectories: true)
        } catch {
            Log.codex.error("creating fixer worktree failed: \(error)")
        }
        if !bound {
            bound = true
            await client.addNotificationHandler { [weak self] method, paramsData in
                let params =
                    (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any]
                switch method {
                case "turn/completed":
                    guard let threadId = params?["threadId"] as? String,
                        let turn = params?["turn"] as? [String: Any],
                        let turnId = turn["id"] as? String,
                        let status = turn["status"] as? String
                    else { return }
                    Task { await self?.turnCompleted(threadId: threadId, turnId: turnId, status: status) }
                default:
                    break
                }
            }
        }
        if let threadId {
            do {
                _ = try await client.request(
                    method: "thread/resume", params: ["threadId": threadId])
            } catch {
                // Designed fallback: a stopped thread resumes only after unarchiving.
                Log.codex.info("thread/resume failed; unarchiving and retrying: \(error)")
                _ = try? await client.request(
                    method: "thread/unarchive", params: ["threadId": threadId])
                _ = try await client.request(
                    method: "thread/resume", params: ["threadId": threadId])
            }
            return
        }

        if let retiredThreadId {
            self.retiredThreadId = nil
            do {
                _ = try await client.request(
                    method: "thread/archive", params: ["threadId": retiredThreadId])
            } catch {
                Log.codex.warning("archiving retired fixer thread failed: \(error)")
            }
        }

        threadId = try await client.startFixerThread(
            cwd: project.rootURL,
            name: project.threadName(for: noteFolderURL, role: "Transcript Fixer"))
        try await startTurn(text: instructions, throughCue: 0)
    }

    /// Called when a cue lands in transcript.vtt.
    public func cueAppended(index: Int) async {
        if index > newestCue { terminalNotified = false }
        newestCue = max(newestCue, index)
        await pingIfIdle()
    }

    /// Final ping at stop; emits `.done` once everything is fixed.
    public func recordingStopped() async {
        stopping = true
        await pingIfIdle()
        finishIfStopped()
    }

    private func turnCompleted(threadId: String, turnId: String, status: String) async {
        guard threadId == self.threadId, let active = pass else { return }
        if active.phase == .starting {
            // A fast turn can complete before turn/start's response arrives.
            // Wait for its id before touching the snapshot or advancing cues.
            pass?.earlyCompletions[turnId] = status
            return
        }
        guard active.phase == .running, active.turnId == turnId else { return }
        guard status == "completed" else {
            Log.codex.warning("fixer turn \(turnId) ended with status \(status); retaining cues for retry")
            failPass()
            return
        }
        pass?.phase = .merging
        // Merge this pass's edits into the live file BEFORE the next pass
        // snapshots it — the next working copy must include them.
        await host?.fixerDidCompletePass()
        lastReviewedCue = max(lastReviewedCue, active.throughCue)
        pass = nil
        eventSink?(.passCompleted)
        await pingIfIdle()  // coalesced pass over everything new
        finishIfStopped()
    }

    private func pingIfIdle() async {
        guard pass == nil, threadId != nil, newestCue > lastReviewedCue else { return }
        let from = lastReviewedCue + 1
        let to = newestCue
        let text =
            from == to
            ? "Cue \(to) is new — review and fix."
            : "Cues \(from)..\(to) are new — review and fix."
        do {
            try await startTurn(text: text, throughCue: to)
        } catch {
            Log.codex.error(
                "fixer ping for cues \(from)..\(to) failed; they stay unfixed until the"
                    + " next pass: \(error)")
        }
    }

    private func startTurn(text: String, throughCue: Int) async throws {
        guard pass == nil, let threadId else { return }
        pass = Pass(throughCue: throughCue)
        failed = false
        terminalNotified = false
        eventSink?(.passStarted)
        // Refresh the working copy from the live file before the model
        // looks at it.
        await host?.fixerWillStartPass()
        pass?.phase = .starting
        do {
            // Workspace-write scoped to the fixer's worktree — the live
            // note folder (transcript.vtt included) is read-only to it.
            let data = try await client.request(
                method: "turn/start",
                params: CodexTurn.startParams(
                    threadId: threadId,
                    text: project.instructions(
                        for: noteFolderURL,
                        taskDirectoryURL: Self.worktreeURL(noteFolder: noteFolderURL),
                        task: text),
                    writableRoot: Self.worktreeURL(noteFolder: noteFolderURL),
                    model: model, effort: effort))
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard let turn = result?["turn"] as? [String: Any], let turnId = turn["id"] as? String
            else { throw CodexWorkerError.malformedResponse }
            let earlyStatus = pass?.earlyCompletions[turnId]
            pass?.turnId = turnId
            pass?.phase = .running
            pass?.earlyCompletions.removeAll()
            if let earlyStatus {
                await turnCompleted(threadId: threadId, turnId: turnId, status: earlyStatus)
            }
        } catch {
            failPass()
            throw error
        }
    }

    private func failPass() {
        pass = nil
        failed = true
        eventSink?(.passFailed)
        finishIfStopped()
    }

    private func finishIfStopped() {
        guard stopping, pass == nil, !terminalNotified else { return }
        if failed {
            terminalNotified = true
            eventSink?(.stoppedAfterFailure)
        } else if threadId != nil, newestCue <= lastReviewedCue {
            terminalNotified = true
            eventSink?(.done)
        }
    }
}
