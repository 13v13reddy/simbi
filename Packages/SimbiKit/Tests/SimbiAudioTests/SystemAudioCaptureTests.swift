import Foundation
import Testing

@testable import SimbiAudio

@Suite("SystemAudioCapture")
struct SystemAudioCaptureTests {
    // Opt in with system audio idle and permission granted to the test runner:
    // SIMBI_TEST_SYSTEM_AUDIO=1 swift test --build-system native --filter SystemAudioCapture
    @Test(
        "delivers real tap buffers while system output is idle, including after restart",
        .enabled(if: ProcessInfo.processInfo.environment["SIMBI_TEST_SYSTEM_AUDIO"] == "1"))
    func deliversBuffersBeforePlayback() async throws {
        guard #available(macOS 14.4, *) else { return }

        for _ in 0..<3 {
            let capture = SystemAudioCapture()
            defer { capture.stop() }
            let stream = try capture.start()
            let firstBatch = await withTaskGroup(of: [Float]?.self) { group in
                group.addTask {
                    for await batch in stream where !batch.isEmpty {
                        return batch
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(2))
                    return nil
                }
                let batch = await group.next() ?? nil
                group.cancelAll()
                return batch
            }

            #expect(firstBatch?.isEmpty == false, "Tap must deliver buffers before playback starts")
        }
    }
}
