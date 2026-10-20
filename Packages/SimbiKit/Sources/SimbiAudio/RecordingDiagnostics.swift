import Dispatch
import SimbiKit

/// Diagnostics must never hold the audio clock or error UI behind disk IO.
public enum RecordingDiagnostics {
    private static let queue = DispatchQueue(label: "app.getsimbi.mac.recording-diagnostics", qos: .utility)

    public static func info(_ message: String) {
        queue.async { Log.recording.info(message) }
    }

    public static func warning(_ message: String) {
        queue.async { Log.recording.warning(message) }
    }

    public static func error(_ message: String) {
        queue.async { Log.recording.error(message) }
    }
}
