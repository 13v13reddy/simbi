import AppKit
import SwiftUI

/// Recording errors remain readable until resolved or acknowledged. Actions
/// wrap onto a separate row so a long explanation never hides how to recover.
struct RecordingProblemBanner: View {
    @Bindable var recorder: RecordingController

    var body: some View {
        if let problem = recorder.problem {
            VStack(alignment: .leading, spacing: Design.rowGap) {
                Label {
                    Text(problem.message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(problem.isFatal ? Color.statusLive : Color.statusWarning)
                }
                .font(.meta)

                HStack(spacing: Design.rowGap) {
                    if !problem.isRecovered && (problem != .microphoneFallback || !recorder.status.isCapturing) {
                        Button(
                            problem.retryTitle(isCapturing: recorder.status.isCapturing)
                        ) {
                            recorder.retryRecording()
                        }
                        .disabled(recorder.isFinalizing)
                    }
                    if let url = problem.settingsURL {
                        Button("Open System Settings") { NSWorkspace.shared.open(url) }
                    }
                    if !problem.isTranscriptProblem && (!recorder.status.isCapturing || problem.isRecovered) {
                        Spacer(minLength: 0)
                        Button("Dismiss") { recorder.dismissProblem() }
                    }
                }
                .font(.metaSemibold)
                .buttonStyle(.link)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, Design.paneInset)
            .padding(.vertical, Design.stripPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((problem.isFatal ? Color.statusLive : Color.statusWarning).opacity(0.1))
            .accessibilityElement(children: .contain)
            Divider()
        }
    }
}
