import AVFoundation
import Foundation
import Testing

@testable import SimbiAudio

/// Decoder tests synthesize fixtures at test time (PCM/afconvert, file-only,
/// silent — never played) and decode them back.
@Suite("MediaFileDecoder")
struct MediaFileDecoderTests {
    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0)
    }

    /// A deterministic two-second tone, then afconvert into the requested container.
    private func fixture(format: [String], ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "decoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = dir.appending(path: "src.caf")
        let out = dir.appending(path: "src.\(ext)")
        // CI runners need not have a working speech-synthesis voice.
        let pcm = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 88200))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) {
            channel[i] = 0.4 * sinf(2 * .pi * 440 * Float(i) / 44100)
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: pcm.settings)
            try file.write(from: buffer)
        }
        try run("/usr/bin/afconvert", format + [source.path, out.path])
        return out
    }

    private func decodeAll(_ url: URL) async throws -> [Float] {
        var samples: [Float] = []
        for try await batch in MediaFileDecoder().decode(url: url) {
            samples.append(contentsOf: batch)
        }
        return samples
    }

    @Test("decodes a wav to 16 kHz mono at the right length")
    func decodesWav() async throws {
        let url = try fixture(format: ["-f", "WAVE", "-d", "LEI16@44100", "-c", "2"], ext: "wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        #expect(abs(seconds - 2) < 0.01)
        let samples = try await decodeAll(url)
        let expected = Int(seconds * 16000)
        #expect(abs(samples.count - expected) < 16000 / 5)  // within 200 ms
        #expect(samples.contains { abs($0) > 0.01 })  // real signal, not zeros
    }

    @Test("decodes an m4a (mp4 container) — the video-container code path")
    func decodesM4a() async throws {
        let url = try fixture(format: ["-f", "m4af", "-d", "aac"], ext: "m4a")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let samples = try await decodeAll(url)
        #expect(abs(samples.count - 32000) < 16000 / 5)  // within 200 ms
        #expect(samples.contains { abs($0) > 0.01 })
    }

    @Test("a non-media file throws")
    func unreadableThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "decoder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "not-audio.mp4")
        try Data("plain text".utf8).write(to: url)
        await #expect(throws: (any Error).self) {
            _ = try await decodeAll(url)
        }
    }

    @Test("file-kind routing")
    func kinds() {
        #expect(MediaFileDecoder.kind(of: "talk.mp4") == .supported)
        #expect(MediaFileDecoder.kind(of: "voice.m4a") == .supported)
        #expect(MediaFileDecoder.kind(of: "song.wav") == .supported)
        #expect(MediaFileDecoder.kind(of: "clip.mov") == .supported)
        #expect(MediaFileDecoder.kind(of: "audio.mp3") == .supported)
        #expect(MediaFileDecoder.kind(of: "video.webm") == .unsupported)
        #expect(MediaFileDecoder.kind(of: "video.mkv") == .unsupported)
        #expect(MediaFileDecoder.kind(of: "audio.ogg") == .unsupported)
        #expect(MediaFileDecoder.kind(of: "notes.pdf") == .document)
        #expect(MediaFileDecoder.kind(of: "README") == .document)
    }
}
