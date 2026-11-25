import SwiftUI
import SwiftData

/// Results (header menu): what was handed to the AI on this device and what came back, newest first. Tap a line
/// to open its item, where the result is. A failed hand-off can be tried again here.
struct ResultsView: View {
    var sel: Selection
    private var queue: JobQueue { JobQueue.shared }

    var body: some View {
        List {
            if queue.jobs.isEmpty {
                Text("Nothing handed off yet. Open an item and tap the wand to hand it to the AI. The result comes back onto the item, and is listed here.")
                    .foregroundStyle(.secondary)
            }
            ForEach(queue.jobs) { job in row(job) }
        }
        .navigationTitle("Results")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Clear finished") { queue.clearFinished() }.disabled(!queue.jobs.contains { !$0.live })
            }
        }
    }

    private func row(_ job: AgentJob) -> some View {
        let fresh = job.nodeID.map { queue.unseen.contains($0) } ?? false
        return HStack(alignment: .top, spacing: 10) {
            icon(job).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title.isEmpty ? "(untitled)" : job.title).fontWeight(fresh ? .semibold : .regular)
                Text(detail(job)).font(.caption).foregroundStyle(job.status == .failed ? Color.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text((job.finishedAt ?? job.createdAt).formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                if job.status == .failed, let id = job.nodeID {
                    Button("Try again") { queue.retry(id) }.buttonStyle(.bordered).controlSize(.small)
                }
                if job.live {
                    Button("Stop") { queue.cancel(job.id) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if fresh { Circle().fill(Color.accentColor).frame(width: 8, height: 8).padding(.top, 6).accessibilityLabel("Not opened yet") }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if let id = job.nodeID, job.kind != .suggest { queue.markSeen(id); sel.open(id) } }
    }

    @ViewBuilder private func icon(_ job: AgentJob) -> some View {
        switch job.status {
        case .queued, .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: job.kind == .suggest ? "lightbulb" : "checkmark.circle.fill")
        case .needsYou: Image(systemName: "person.crop.circle.badge.exclamationmark")
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func detail(_ job: AgentJob) -> String {
        switch job.status {
        case .queued: "Waiting to start"
        case .working: job.route == .background ? "Working. This goes on with the app closed." : "Working. Keep the app open."
        case .failed: job.error.isEmpty ? "Did not finish." : job.error
        case .done, .needsYou: job.summary
        }
    }
}
