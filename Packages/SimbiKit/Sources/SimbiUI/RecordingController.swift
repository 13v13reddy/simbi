import AVFoundation
import CodexKit
import Foundation
import Observation
import SimbiAudio
import SimbiKit

/// Owns the mic capture and recording pipeline for one open note and
/// exposes UI-facing state (SPEC.md §6: Record/Stop/Resume with live
/// elapsed time and speaker indicator).
@MainActor
@Observable
public final class RecordingController {
    /// One controller (and pipeline) per note folder, however many times
    /// the note view is recreated — two pipelines writing one note's files
    /// would corrupt the timeline.
    private static let controllers = PerNoteRegistry<RecordingController>()

    public static func shared(noteFolderURL: URL) -> RecordingController {
        controllers.value(for: noteFolderURL, make: RecordingController.init(noteFolderURL:))
    }

    /// True while any open note is capturing. The auto-updater reads this to
    /// keep an install from ever interrupting a meeting (`UpdateGate`).
    public static var isAnyRecording: Bool {
        controllers.all.contains { $0.status.isCapturing }
    }

    /// The note currently capturing, if any. The menubar recorder uses this
    /// to stop a recording without opening the main window.
    public static var activeStatus: Status? {
        controllers.all.first(where: { $0.status.isCapturing })?.status
    }

    public static var activeNoteFolderURL: URL? {
        controllers.all.first(where: { $0.status.isCapturing })?.noteFolderURL
    }

    /// True while THIS note is capturing. Read-only — never creates a
    /// controller as a side effect. The summary controller uses it to
    /// refuse generation triggers mid-recording (AI Notes spec §3).
    static func isCapturing(noteFolderURL: URL) -> Bool {
        controllers[noteFolderURL]?.status.isCapturing ?? false
    }

    static var protectedNoteFolders: [URL] {
        controllers.all.filter {
            $0.status.isCapturing || $0.isFinalizing || $0.pendingStopNotification
                || $0.pipeline.hasPendingTranscriptWork
                || $0.fixerActivity.status == .working || $0.fixerActivity.status == .waiting
        }.map(\.noteFolderURL)
    }

    static func finishAllForQuit() async -> Bool {
        var saved = true
        for controller in controllers.all where controller.status.isCapturing || controller.isFinalizing {
            if !(await controller.finishForQuit()) { saved = false }
        }
        return saved
    }

    func finishForQuit() async -> Bool {
        if status.isCapturing && !isFinalizing {
            await finish(failure: nil, waitForPreparation: status == .preparing && capture == nil, forQuit: true)
        }
        while isFinalizing { try? await Task.sleep(for: .milliseconds(20)) }
        if case .failed = status { return false }
        guard let state = try? NoteRecordingState.load(noteFolder: noteFolderURL) else { return false }
        return state.activeSession == nil
    }

    public enum Status: Equatable {
        case idle
        /// Requesting mic permission. Models come preloaded from
        /// `SpeechModelPool` (warmed at app launch); only the very first
        /// run may still download here.
        case preparing
        case recording
        case stopping
        case failed(String)

        /// Audio is (or is about to be) flowing — the window in which an app
        /// relaunch would cost the user their meeting.
        var isCapturing: Bool {
            switch self {
            case .preparing, .recording, .stopping: true
            case .idle, .failed: false
            }
        }
    }

    private(set) var status: Status = .idle {
        didSet { activity.refresh() }
    }
    /// Note-timeline seconds, live while recording.
    private(set) var elapsed: TimeInterval = 0
    /// Tentative live indicator slot ("Speaker N speaking…"), display-only.
    private(set) var tentativeSpeaker: Int?
    /// True when the note already has a recording (button says Resume).
    private(set) var hasRecording: Bool
    /// Recording sources (SPEC.md §3.1: mic and system audio are chosen
    /// independently; at least one stays on — the UI disables the last
    /// active option). Defaults come from settings.json and changes persist
    /// back as the new default.
    var micEnabled: Bool {
        didSet { persistSources() }
    }
    /// Specific input device UID; nil follows the system default.
    var micDeviceUID: String? {
        didSet { persistSources() }
    }
    var systemAudioEnabled: Bool {
        didSet { persistSources() }
    }
    /// Set when a requested source degraded at start (system tap couldn't
    /// start, saved mic not connected) — recording proceeds with what's
    /// left under this banner (SPEC.md §7).
    var systemAudioBanner: String? {
        guard let problem, !problem.isFatal else { return nil }
        return problem.message
    }
    private var audioProblem: RecordingProblem? {
        didSet { refreshProblem() }
    }
    private var transcriptSaveFailed = false {
        didSet { refreshProblem() }
    }
    private var transcriptionFailed = false {
        didSet { refreshProblem() }
    }
    private(set) var problem: RecordingProblem? {
        didSet {
            guard problem != oldValue else { return }
            persistProblem()
            if let problem {
                activity.report(problem, noteFolderURL: noteFolderURL)
                if problem.isRecovered {
                    notifier.clear(noteFolderURL: noteFolderURL)
                } else {
                    notifier.post(problem: problem, noteFolderURL: noteFolderURL)
                }
            } else {
                activity.clearProblem(noteFolderURL: noteFolderURL)
                notifier.clear(noteFolderURL: noteFolderURL)
            }
        }
    }
    private(set) var isFinalizing = false
    var canStop: Bool { capture != nil && !isFinalizing }
    var canRetry: Bool { !isFinalizing && (status == .idle || !status.isCapturing) }

    /// Input devices for the source menu, re-read on each open so plugging
    /// in a mic shows up without a restart.
    var availableMicrophones: [AudioInputDevice] {
        AudioInputDevices.list()
    }

    /// Coarse fixer status (off/waiting/working/done) for the header button.
    let fixerActivity = FixerActivityModel()

    /// Fired after a clean stop (status back to .idle) so the summary
    /// controller can generate AI notes (AI Notes spec §3). Assigned by
    /// the note view; both controllers are app-lifetime singletons.
    var onRecordingStopped: (() -> Void)?

    /// Whether this note has a fixer thread (saved in state.json, or created
    /// this session). Drives the header button's visibility across relaunches.
    private(set) var hasFixerThread: Bool

    /// Exposed so the header's buttons can open per-note windows keyed by
    /// this URL.
    let noteFolderURL: URL
    private let pipeline: RecordingPipeline
    private var capture: (any RecordingCapturing)?
    private let makeCapture: @Sendable () -> any RecordingCapturing
    private let requestMicrophoneAccess: @MainActor @Sendable () async -> Bool
    private let healthPolicy: RecordingHealthPolicy
    private let notifier: any RecordingNotifying
    private let activity: RecordingActivity
    private let enableFixer: Bool
    private let persistSourcePreferences: Bool
    private var healthTask: Task<Void, Never>?
    private var preparationDeadline: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var generation = 0
    private var captureStartedAt: TimeInterval?
    private var selectionWarning: RecordingProblem?
    private var ingestTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var pendingStopNotification = false
    private var watcher: FileTreeWatcher?

    public convenience init(noteFolderURL: URL) {
        self.init(
            noteFolderURL: noteFolderURL,
            pipeline: RecordingPipeline(
                noteFolderURL: noteFolderURL, transcriber: CodexTranscriber(), diarizer: SortformerStream(),
                outbox: .shared(noteFolderURL: noteFolderURL)),
            makeCapture: { MixedCapture() },
            requestMicrophoneAccess: { await AVCaptureDevice.requestAccess(for: .audio) },
            notifier: RecordingNotifications.shared, enableFixer: true, persistSourcePreferences: true)
    }

    init(
        noteFolderURL: URL, pipeline: RecordingPipeline,
        makeCapture: @escaping @Sendable () -> any RecordingCapturing,
        requestMicrophoneAccess: @escaping @MainActor @Sendable () async -> Bool,
        healthPolicy: RecordingHealthPolicy = RecordingHealthPolicy(),
        notifier: any RecordingNotifying, activity: RecordingActivity = .shared, enableFixer: Bool = false,
        persistSourcePreferences: Bool = false
    ) {
        self.noteFolderURL = noteFolderURL
        self.pipeline = pipeline
        self.makeCapture = makeCapture
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.healthPolicy = healthPolicy
        self.notifier = notifier
        self.activity = activity
        self.enableFixer = enableFixer
        self.persistSourcePreferences = persistSourcePreferences
        let storedProblem = StoredRecordingProblem.load(noteFolder: noteFolderURL)
        self.problem = storedProblem
        self.audioProblem = storedProblem?.isTranscriptProblem == true ? nil : storedProblem
        self.transcriptSaveFailed = storedProblem == .transcriptSaveFailed
        self.transcriptionFailed = storedProblem == .transcriptionFailed
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        self.hasRecording = state.sessionCount > 0 || state.activeSession != nil
        self.hasFixerThread = state.fixerThreadId != nil
        self.elapsed = TimeInterval(state.totalSamples) / TimeInterval(CutConstants.sampleRate)
        let settings = SimbiSettings.current()
        self.micEnabled = settings.micEnabled
        self.micDeviceUID = settings.micDeviceUID
        self.systemAudioEnabled = settings.systemAudioEnabled
        watcher = FileTreeWatcher.observing(url: noteFolderURL) { [weak self] in
            self?.refreshFileState()
        }
        if let problem { activity.report(problem, noteFolderURL: noteFolderURL) }
        observeTranscriptSaving()
    }

    private func observeTranscriptSaving() {
        guard transcriptTask == nil, NoteRecordingState.current(noteFolder: noteFolderURL).activeImport == nil else {
            return
        }
        transcriptTask = Task { [pipeline, weak self] in
            await pipeline.retryTranscriptSaving()
            for await failed in await pipeline.transcriptSaveUpdates() {
                guard !Task.isCancelled else { return }
                self?.transcriptSaveFailed = failed
            }
        }
        transcriptionTask = Task { [pipeline, weak self] in
            for await failed in await pipeline.transcriptionUpdates() {
                guard !Task.isCancelled else { return }
                self?.transcriptionFailed = failed
            }
        }
    }

    func reportTranscriptSaveFailure(_ failed: Bool) {
        transcriptSaveFailed = failed
    }

    func reportTranscriptionFailure(_ failed: Bool) { transcriptionFailed = failed }

    isolated deinit {
        healthTask?.cancel()
        preparationDeadline?.cancel()
        startTask?.cancel()
        ingestTask?.cancel()
        liveTask?.cancel()
        transcriptTask?.cancel()
        transcriptionTask?.cancel()
        capture?.stop()
    }

    /// state.json is also plain-file state. Adopt external bookkeeping while
    /// idle; during capture the live pipeline remains its single writer.
    func refreshFileState() {
        guard status == .idle else { return }
        let state = NoteRecordingState.current(noteFolder: noteFolderURL)
        hasRecording = state.sessionCount > 0 || state.activeSession != nil
        hasFixerThread = state.fixerThreadId != nil
        elapsed = TimeInterval(state.totalSamples) / TimeInterval(CutConstants.sampleRate)
    }

    private func persistSources() {
        guard persistSourcePreferences else { return }
        let home = SimbiHome()
        var settings = SimbiSettings.current(home: home)
        settings.micEnabled = micEnabled
        settings.micDeviceUID = micDeviceUID
        settings.systemAudioEnabled = systemAudioEnabled
        do {
            try settings.save(to: home.settingsFileURL)
        } catch {
            Log.ui.error("persisting recording sources to settings.json failed: \(error)")
        }
    }

    /// Pipeline Inspector stream for this note's pipeline (the pipeline
    /// itself is private to the controller).
    public func inspectorUpdates() async -> AsyncStream<InspectorUpdate> {
        await pipeline.inspectorUpdates()
    }

    /// The header's sparkles button: open the note's fixer thread in the
    /// live thread viewer. Fixer viewers never archive on close; the thread
    /// stays resumable with full context (spec 2026-08-09).
    func openFixerViewer() {
        guard let threadId = NoteRecordingState.current(noteFolder: noteFolderURL).fixerThreadId
        else { return }
        ThreadViewerManager.shared.open(
            threadId: threadId,
            title: "Fixer: \(noteFolderURL.lastPathComponent)",
            noteFolderURL: noteFolderURL,
            archivesOnClose: false,
            isBusy: { [weak self] in self?.fixerActivity.status == .working })
    }

    public func toggle() {
        switch status {
        case .idle, .failed:
            startRecording()
        case .recording:
            Task { await stop() }
        case .preparing:
            if canStop { Task { await stop() } }
        case .stopping:
            break
        }
    }

    /// Starts this note's recording without requiring a visible NoteView.
    /// Quick capture uses this entry point after creating the note folder.
    public func startRecording() {
        guard canRetry, !ApplicationQuitCoordinator.shared.isQuitting else { return }
        observeTranscriptSaving()
        generation += 1
        let generation = generation
        status = .preparing
        startTask = Task { [weak self] in await self?.start(generation: generation) }
    }

    private func start(generation: Int) async {
        audioProblem = nil
        selectionWarning = nil
        notifier.prepare()
        // An import owns the note's timeline (state.json sessionCount /
        // totalSamples) while it runs; a concurrent recording would clobber
        // it. The other direction holds too: ImportController's worker
        // waits while this note is capturing.
        guard !ImportController.isImporting(noteFolderURL: noteFolderURL) else {
            status = .failed(
                "A file import is transcribing into this note. Wait for it to finish first.")
            return
        }
        if micEnabled {
            let granted = await requestMicrophoneAccess()
            guard generation == self.generation else { return }
            if !granted {
                if !systemAudioEnabled {
                    audioProblem = .microphonePermission
                    status = .failed(RecordingProblem.microphonePermission.message)
                    return
                }
                selectionWarning = .microphonePermissionFallback
            }
        }
        preparationDeadline = Task { [weak self, healthPolicy] in
            do { try await Task.sleep(for: .seconds(healthPolicy.preparationTimeout)) } catch { return }
            guard let self, generation == self.generation, captureStartedAt == nil else { return }
            RecordingDiagnostics.error("recording preparation timed out")
            await finish(failure: .startupFailed, waitForPreparation: true)
        }
        do {
            // Fixer (SPEC.md §5.2): reuses the note's saved thread if any.
            // A thread created under older instructions — a contract
            // version bump or a user edit to FIXER.md — is retired; a
            // fresh thread with the current prompt starts instead.
            let settings = SimbiSettings.current()
            if enableFixer && settings.transcriptFixerEnabled {
                let noteState = NoteRecordingState.current(noteFolder: noteFolderURL)
                let fixerInstructions = AgentInstructions.fixer.resolve(
                    homeRootURL: SimbiHome().rootURL)
                let canResumeSavedThread =
                    noteState.fixerInstructionsVersion == TranscriptFixer.instructionsVersion
                    && noteState.fixerInstructionsHash
                        == AgentInstructions.fingerprint(fixerInstructions)
                let savedThreadId = canResumeSavedThread ? noteState.fixerThreadId : nil
                let retiredThreadId = canResumeSavedThread ? nil : noteState.fixerThreadId
                let choice = settings[.fixer]
                let fixer = TranscriptFixer(
                    noteFolderURL: noteFolderURL, client: CodexServices.appServer,
                    savedThreadId: savedThreadId, retiredThreadId: retiredThreadId,
                    model: choice.model,
                    effort: choice.effort,
                    instructions: fixerInstructions)
                let activity = fixerActivity
                await fixer.setEventSink { event in
                    Task { @MainActor in activity.handle(event) }
                }
                await pipeline.attachFixer(fixer)
            } else {
                await pipeline.attachFixer(nil)
            }
            try await pipeline.start()
            guard generation == self.generation else { return }
            preparationDeadline?.cancel()
            preparationDeadline = nil
            // Refresh right after pipeline.start(): that's where the fixer
            // thread is (or isn't) created. When codex is unavailable no
            // thread exists, the status stays .off, and the sparkles button
            // stays hidden (degraded state, SPEC.md §8).
            if enableFixer && settings.transcriptFixerEnabled {
                hasFixerThread =
                    NoteRecordingState.current(noteFolder: noteFolderURL).fixerThreadId != nil
                if hasFixerThread {
                    fixerActivity.noteRecordingStarted()
                }
            }
            let capture = makeCapture()
            self.capture = capture
            // A saved mic that's unplugged degrades to the default device
            // (with a banner) rather than blocking the recording.
            var deviceUID = micDeviceUID
            if micEnabled, let uid = deviceUID, AudioInputDevices.deviceID(forUID: uid) == nil {
                deviceUID = nil
                selectionWarning = .microphoneFallback
            }
            let stream = try capture.startBatches(
                config: .init(
                    micEnabled: micEnabled,
                    micDeviceUID: deviceUID,
                    systemAudioEnabled: systemAudioEnabled))
            captureStartedAt = ProcessInfo.processInfo.systemUptime
            healthTask = Task { [weak self, healthPolicy] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(healthPolicy.checkInterval)) } catch { return }
                    await self?.checkHealth()
                }
            }

            liveTask = Task { [pipeline, weak self] in
                for await update in await pipeline.liveUpdates() {
                    guard let self else { return }
                    self.elapsed = max(self.elapsed, update.elapsed)
                    self.tentativeSpeaker = update.tentativeSpeaker
                }
            }
            ingestTask = Task.detached(priority: .userInitiated) { [pipeline, weak self, capture] in
                for await batch in stream {
                    guard !Task.isCancelled else { return }
                    do {
                        try await pipeline.ingest(
                            samples: batch.samples, capturedSampleCount: batch.capturedSampleCount)
                    } catch {
                        RecordingDiagnostics.error("recording ingest failed: \(error)")
                        capture.stop()
                        Task { @MainActor [weak self] in await self?.finish(failure: .recordingFailed) }
                        return
                    }
                }
            }
        } catch {
            guard generation == self.generation else { return }
            RecordingDiagnostics.error("recording startup failed: \(error)")
            await finish(failure: .startupFailed)
        }
    }

    func checkHealth() async {
        guard !isFinalizing, let capture, let started = captureStartedAt else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let saved = pipeline.writeProgress.snapshot
        let sources = capture.sourceHealth
        if status == .preparing, saved.capturedSamples > 0, saved.fileBytes > saved.initialBytes {
            status = .recording
            hasRecording = true
        }
        elapsed = max(elapsed, saved.elapsed)
        if status == .preparing, now - started >= healthPolicy.startupTimeout {
            await finish(failure: sources.contains(where: { $0.receivedSamples > 0 }) ? .writeStalled : .noAudio)
            return
        }
        if status == .recording {
            let unsavedSeconds =
                Double(max(0, capture.producedSamples - saved.writtenSamples))
                / Double(CutConstants.sampleRate)
            if now - (saved.lastWriteTime ?? started) >= healthPolicy.writeTimeout
                || unsavedSeconds >= healthPolicy.writeTimeout
            {
                await finish(failure: .writeStalled)
                return
            }
            let lastInput = sources.compactMap(\.lastSampleTime).max() ?? started
            if now - lastInput >= healthPolicy.sourceTimeout {
                await finish(failure: .noAudio)
                return
            }
        }
        if let missing = sources.first(where: { $0.state == .recovering || $0.state == .unavailable }),
            sources.contains(where: { $0.state == .active })
        {
            if missing.source == .microphone, selectionWarning == .microphonePermissionFallback {
                audioProblem = .microphonePermissionFallback
            } else {
                audioProblem = .sourceUnavailable(missing.source, retrying: missing.state == .recovering)
            }
        } else if sources.allSatisfy({ $0.state == .active }) {
            if selectionWarning == .microphonePermissionFallback { selectionWarning = nil }
            if case .sourceUnavailable(let source, _) = audioProblem {
                audioProblem = .sourceRecovered(source)
            } else if audioProblem == .microphonePermissionFallback {
                audioProblem = .sourceRecovered(.microphone)
            } else if audioProblem?.isRecovered != true {
                audioProblem = selectionWarning
            }
        }
    }

    public func retryUnavailableSources() {
        guard !isFinalizing, let capture else { return }
        capture.retryUnavailableSources()
    }

    /// A notification can outlive its capture, including an app relaunch.
    /// Retry the missing source during a recording or resume the note otherwise.
    func retryRecording() {
        if problem == .transcriptSaveFailed {
            retryTranscriptSaving()
        } else if problem == .transcriptionFailed {
            retryTranscription()
        } else if status.isCapturing {
            retryUnavailableSources()
        } else {
            startRecording()
        }
    }

    func retryTranscriptSaving() {
        if NoteRecordingState.current(noteFolder: noteFolderURL).activeImport?.phase == 2 {
            ImportController.shared(noteFolderURL: noteFolderURL).retryTranscriptSaving()
        } else {
            Task { [pipeline] in await pipeline.retryTranscriptSaving() }
        }
    }

    func retryTranscription() {
        if NoteRecordingState.current(noteFolder: noteFolderURL).activeImport?.phase == 2 {
            Task { [pipeline] in await pipeline.resumePausedTranscription() }
            ImportController.shared(noteFolderURL: noteFolderURL).retryTranscription()
        } else {
            Task { [pipeline] in await pipeline.retryTranscription() }
        }
    }

    public func dismissProblem() {
        guard problem?.isTranscriptProblem != true, (!status.isCapturing || problem?.isRecovered == true), !isFinalizing
        else { return }
        audioProblem = nil
        if !status.isCapturing { status = .idle }
    }

    public func stopRecording() async { await stop() }

    private func stop() async {
        await finish(failure: nil, waitForPreparation: status == .preparing && capture == nil)
    }

    private func finish(failure: RecordingProblem?, waitForPreparation: Bool = false, forQuit: Bool = false) async {
        guard !isFinalizing else { return }
        isFinalizing = true
        generation += 1
        preparationDeadline?.cancel()
        preparationDeadline = nil
        let pendingPreparation = startTask
        startTask?.cancel()
        startTask = nil
        if let failure { audioProblem = failure }
        status = .stopping
        healthTask?.cancel()
        healthTask = nil
        captureStartedAt = nil
        capture?.stop()
        capture = nil
        if waitForPreparation {
            if forQuit {
                // Invalidates the actor's preparation token before a model or
                // permission request returns, without waiting on that request.
                try? await pipeline.abort(runFixer: false)
            } else {
                await pendingPreparation?.value
            }
        }
        // A failing model/write must not hold a hardware source open. Cancel
        // its ingestion before waiting for the actor to finalize saved audio.
        if failure != nil { ingestTask?.cancel() }
        await ingestTask?.value
        ingestTask = nil
        liveTask?.cancel()
        liveTask = nil
        var terminalFailure = failure
        do {
            if failure != nil {
                try await pipeline.abort(runFixer: !forQuit)
            } else if forQuit, !(await pipeline.isRecording) {
                try await pipeline.abort(runFixer: false)
            } else {
                try await pipeline.stop(runFixer: !forQuit)
            }
        } catch {
            RecordingDiagnostics.error("finalizing recording failed: \(error)")
            terminalFailure = terminalFailure ?? .recordingFailed
            audioProblem = terminalFailure
            do { try await pipeline.abort(runFixer: !forQuit) } catch {
                RecordingDiagnostics.error("preserving partial recording failed: \(error)")
            }
        }
        isFinalizing = false
        tentativeSpeaker = nil
        if let terminalFailure {
            audioProblem = terminalFailure
            status = .failed(terminalFailure.message)
        } else {
            status = .idle
            if case .sourceUnavailable(let source, _) = audioProblem {
                audioProblem = .sourceUnavailable(source, retrying: false)
            }
            if !forQuit { notifyStoppedAfterTranscriptDrain() }
        }
    }

    private func refreshProblem() {
        problem =
            audioProblem?.isFatal == true
            ? audioProblem
            : transcriptSaveFailed ? .transcriptSaveFailed : transcriptionFailed ? .transcriptionFailed : audioProblem
    }

    private func persistProblem() {
        StoredRecordingProblem.save(problem, noteFolder: noteFolderURL)
    }

    /// Fires `onRecordingStopped` only after the pending-upload queue has
    /// drained (bounded — AI Notes spec §3): `pipeline.stop()` returns
    /// while the final cues' transcriptions are still in flight, and the
    /// summary must not be generated from a transcript missing its last
    /// utterances. Degraded recordings never drain; when the bound
    /// expires the trigger fires with whatever transcript exists (an
    /// empty one is skipped quietly downstream). A recording restarted
    /// during the wait swallows the trigger: no trigger while recording.
    private func notifyStoppedAfterTranscriptDrain() {
        pendingStopNotification = true
        Task { [pipeline] in
            defer { pendingStopNotification = false }
            _ = await TranscriptDrainWait.wait {
                await pipeline.isTranscriptDrained
            }
            guard status == .idle, !ApplicationQuitCoordinator.shared.isQuitting else { return }
            onRecordingStopped?()
        }
    }

}
