import Foundation
import SimbiKit

/// Microphone and system-audio RMS for one 80 ms note-timeline frame.
public struct SourceLevel: Equatable, Sendable {
    public var microphone: Float
    public var system: Float

    public init(microphone: Float, system: Float) {
        self.microphone = microphone
        self.system = system
    }
}

/// The two sources before mixing, sample-aligned with a mixed batch.
public struct SourceSamples: Sendable {
    public let microphone: [Float]
    public let system: [Float]

    public init(microphone: [Float], system: [Float]) {
        self.microphone = microphone
        self.system = system
    }
}

/// Appends per-frame source levels to `.simbi/source-levels.f32` at their
/// note-timeline positions. Best effort by design: any file error disables
/// the writer for the session and never affects the recording itself.
final class SourceLevelsWriter {
    static let recordBytes = 2 * MemoryLayout<Float32>.size

    private var handle: FileHandle?
    /// Note-timeline sample index of the next sample to account for.
    private var position: Int
    private var frameMicrophone: Double = 0
    private var frameSystem: Double = 0
    private var frameCount = 0
    /// Completed records not yet written, starting at `pendingFrame`.
    private var pending: [Float32] = []
    private var pendingFrame: Int

    init?(url: URL, startSample: Int) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: url)
        } catch {
            RecordingDiagnostics.warning("source levels unavailable for this session: \(error)")
            return nil
        }
        position = startSample
        pendingFrame = startSample / CutConstants.frameSamples
    }

    deinit { try? handle?.close() }

    /// Accounts for `count` mixed samples. Without `sources` (imports, tests)
    /// the frames are skipped and later read back as unknown.
    func append(count: Int, sources: SourceSamples?) {
        guard handle != nil, count > 0 else { return }
        guard let sources, sources.microphone.count >= count, sources.system.count >= count else {
            // A gap: drop the partial frame and restart at the new position.
            write()
            resetFrame()
            position += count
            pendingFrame = position / CutConstants.frameSamples
            return
        }
        for index in 0..<count {
            let microphone = Double(sources.microphone[index])
            let system = Double(sources.system[index])
            frameMicrophone += microphone * microphone
            frameSystem += system * system
            frameCount += 1
            position += 1
            if position % CutConstants.frameSamples == 0 { closeFrame() }
        }
        write()
    }

    /// Writes the trailing partial frame and closes the file.
    func finish() {
        if frameCount > 0 { closeFrame() }
        write()
        try? handle?.close()
        handle = nil
    }

    private func closeFrame() {
        let count = Double(max(frameCount, 1))
        pending.append(Float32((frameMicrophone / count).squareRoot()))
        pending.append(Float32((frameSystem / count).squareRoot()))
        resetFrame()
    }

    private func resetFrame() {
        frameMicrophone = 0
        frameSystem = 0
        frameCount = 0
    }

    private func write() {
        guard let handle, !pending.isEmpty else { return }
        do {
            try handle.seek(toOffset: UInt64(pendingFrame * Self.recordBytes))
            try handle.write(contentsOf: pending.withUnsafeBufferPointer { Data(buffer: $0) })
            pendingFrame += pending.count / 2
            pending.removeAll(keepingCapacity: true)
        } catch {
            RecordingDiagnostics.warning("writing source levels failed; disabled for this session: \(error)")
            try? handle.close()
            self.handle = nil
        }
    }

    /// Reads every frame; missing or unreadable files yield no levels.
    static func read(url: URL) -> [SourceLevel] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.withUnsafeBytes { raw in
            (0..<(raw.count / recordBytes)).map { frame in
                let offset = frame * recordBytes
                return SourceLevel(
                    microphone: raw.loadUnaligned(fromByteOffset: offset, as: Float32.self),
                    system: raw.loadUnaligned(fromByteOffset: offset + 4, as: Float32.self))
            }
        }
    }
}
