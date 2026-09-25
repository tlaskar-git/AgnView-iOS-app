import SwiftUI

extension JobStatus {
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .revisionInProgress: return "Revising"
        case .failed: return "Failed"
        case .unknown(let value): return value.capitalized
        }
    }

    var tint: Color {
        switch self {
        case .completed: return Theme.success
        case .failed: return Theme.error
        case .inProgress, .revisionInProgress: return Theme.action
        default: return Theme.textSecondary
        }
    }
}

extension TaskStatus {
    var label: String {
        switch self {
        case .pending: return "Pending"
        case .ready: return "Ready"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .revisionRequested: return "Revision requested"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        case .unknown(let value): return value.capitalized
        }
    }

    var tint: Color {
        switch self {
        case .completed: return Theme.success
        case .failed, .blocked: return Theme.error
        case .inProgress, .ready: return Theme.action
        case .revisionRequested: return Theme.warning
        default: return Theme.textSecondary
        }
    }
}

struct PipelinesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScreenChrome(screen: .pipelines) {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let notice = model.jobsNotice {
                    Banner(kind: .info, text: notice, identifier: "pipelines-notice")
                }
                if model.jobs.isEmpty {
                    Text(model.jobsNotice == nil ? "No pipelines yet." : "No pipeline reading on this connection.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                        .accessibilityIdentifier("pipelines-empty")
                } else {
                    ForEach(model.jobs) { job in
                        NavigationLink {
                            JobDetailView(jobId: job.id)
                        } label: {
                            JobRow(job: job)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("job-row")
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .task(id: model.jobsAreLive) {
            while !Task.isCancelled {
                await model.refreshJobs()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
}

private func completedCount(_ job: Job) -> Int {
    job.tasks.filter { $0.status == .completed }.count
}

struct JobRow: View {
    let job: Job

    var body: some View {
        let done = completedCount(job)
        let total = job.tasks.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(job.title)
                    .font(.headline)
                    .foregroundStyle(Theme.textMain)
                    .multilineTextAlignment(.leading)
                Spacer()
                StatusPill(text: job.status.label, tint: job.status.tint)
            }
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .tint(job.status.tint)
            Text(total == 0 ? "No tasks yet" : "\(done) of \(total) tasks done")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(minHeight: Theme.minTap)
        .card()
        .accessibilityElement(children: .combine)
    }
}

struct JobDetailView: View {
    let jobId: String
    @EnvironmentObject private var model: AppModel

    private var job: Job? { model.jobs.first { $0.id == jobId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let job {
                    HStack(alignment: .top) {
                        Text(job.title)
                            .font(.title2.bold())
                            .foregroundStyle(Theme.textMain)
                        Spacer()
                        StatusPill(text: job.status.label, tint: job.status.tint)
                    }
                    if let description = job.description, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    JobRow(job: job)
                    Text("Tasks")
                        .font(.headline)
                        .foregroundStyle(Theme.textMain)
                    ForEach(job.tasks) { task in
                        TaskRow(task: task)
                    }
                } else {
                    Text("This pipeline is no longer listed.")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(Theme.screenPadding)
        }
        .background(Theme.page.ignoresSafeArea())
        .navigationTitle("Pipeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .accessibilityIdentifier("job-detail")
    }
}

struct TaskRow: View {
    let task: PipelineTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textMain)
                Spacer()
                StatusPill(text: task.status.label, tint: task.status.tint)
            }
            if let agent = task.assignedAgent, !agent.isEmpty {
                Text(Format.agentName(agent))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let summary = task.outputSummary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(4)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}
