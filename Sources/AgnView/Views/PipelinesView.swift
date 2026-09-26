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

/// A pipeline the screen opens by itself, for example right after it is created.
struct OpenedJob: Hashable {
    let id: String
}

struct PipelinesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showNew = false
    @State private var opened: OpenedJob?

    var body: some View {
        ScreenChrome(screen: .pipelines, onRefresh: { await model.refreshJobs() }) {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .center) {
                    Text("Tap a pipeline to open its tasks")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(Color.white)
                            .frame(width: Theme.minTap, height: Theme.minTap)
                            .background(Circle().fill(Theme.action))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canManageJobs)
                    .opacity(model.canManageJobs ? 1 : 0.4)
                    .accessibilityLabel("New pipeline")
                    .accessibilityIdentifier("pipelines-new")
                }
                if let notice = model.jobsNotice {
                    Banner(kind: .info, text: notice, identifier: "pipelines-notice")
                } else if let notice = model.pipelineCreateNotice {
                    Banner(kind: .info, text: notice, identifier: "pipelines-create-notice")
                }
                if let message = model.jobsState.failureMessage {
                    PanelErrorCard(message: message, prefix: "pipelines") {
                        Task { await model.retryJobs() }
                    }
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
                            JobRow(job: job, reservesMenuSpace: true)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .topTrailing) {
                            PipelineMenu(job: job, popsOnDelete: false)
                                .padding(.top, 8)
                                .padding(.trailing, 8)
                        }
                        .accessibilityIdentifier("job-row")
                    }
                }
            }
            .padding(.bottom, 16)
            .background {
                // Opens the new pipeline. A link rather than a navigation
                // destination, so it also works in the iPad detail column.
                NavigationLink(isActive: Binding(get: { opened != nil },
                                                 set: { if !$0 { opened = nil } })) {
                    if let opened { JobDetailView(jobId: opened.id) }
                } label: {
                    EmptyView()
                }
                .hidden()
                .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $showNew) {
            NewPipelineView { job in
                opened = OpenedJob(id: job.id)
            }
            .environmentObject(model)
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
    /// Leaves room at the top right for the overflow menu.
    var reservesMenuSpace = false

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
                if reservesMenuSpace {
                    Color.clear.frame(width: Theme.minTap - 8, height: 1)
                }
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

/// The overflow menu of a pipeline: the actions hub 0.1.12 supports.
struct PipelineMenu: View {
    enum TaskAction: String, Identifiable {
        case revision
        case fail
        var id: String { rawValue }
    }

    let job: Job
    /// True in the detail screen, which closes itself after a delete.
    let popsOnDelete: Bool

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var taskAction: TaskAction?
    @State private var confirmDelete = false
    @State private var deleteError: String?

    private var openTasks: [PipelineTask] {
        job.tasks.filter { $0.status != .completed && $0.status != .failed }
    }

    var body: some View {
        Menu {
            Button {
                taskAction = .revision
            } label: {
                Label("Request revision", systemImage: "arrow.uturn.backward")
            }
            .disabled(job.tasks.isEmpty || !model.canActOnTasks)
            .accessibilityIdentifier("job-menu-revision")
            Button {
                taskAction = .fail
            } label: {
                Label("Mark failed", systemImage: "xmark.octagon")
            }
            .disabled(openTasks.isEmpty || !model.canActOnTasks)
            .accessibilityIdentifier("job-menu-fail")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete pipeline", systemImage: "trash")
            }
            .disabled(!model.canManageJobs)
            .accessibilityIdentifier("job-menu-delete")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.minTap - 8, height: Theme.minTap - 8)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Pipeline actions")
        .accessibilityIdentifier("job-menu")
        .sheet(item: $taskAction) { action in
            TaskActionSheet(job: job, action: action, tasks: action == .fail ? openTasks : job.tasks)
                .environmentObject(model)
        }
        .confirmationDialog("Delete \"\(job.title)\"?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete pipeline", role: .destructive) {
                Task {
                    do {
                        try await model.deletePipeline(id: job.id)
                        if popsOnDelete { dismiss() }
                    } catch {
                        deleteError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the pipeline and its tasks from the hub.")
        }
        .alert("The pipeline was not deleted", isPresented: Binding(get: { deleteError != nil },
                                                                     set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }
}

/// Request a revision of a task, or mark it failed. Both need a written reason.
struct TaskActionSheet: View {
    let job: Job
    let action: PipelineMenu.TaskAction
    let tasks: [PipelineTask]

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var taskId = ""
    @State private var text = ""
    @State private var submitting = false
    @State private var failure: String?

    private var title: String { action == .revision ? "Request revision" : "Mark failed" }
    private var fieldTitle: String { action == .revision ? "What should change" : "Why it failed" }
    private var canSubmit: Bool {
        !submitting && !taskId.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    Picker("Task", selection: $taskId) {
                        ForEach(tasks) { task in
                            Text(task.title.isEmpty ? task.id : task.title).tag(task.id)
                        }
                    }
                    .accessibilityIdentifier("task-action-task")
                }
                Section(fieldTitle) {
                    TextField(fieldTitle, text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("task-action-text")
                }
                if let failure {
                    Section {
                        Text(failure)
                            .foregroundStyle(Theme.error)
                            .accessibilityIdentifier("task-action-error")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action == .revision ? "Send" : "Mark failed") { Task { await submit() } }
                        .disabled(!canSubmit)
                        .accessibilityIdentifier("task-action-submit")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if taskId.isEmpty { taskId = tasks.first?.id ?? "" }
        }
    }

    private func submit() async {
        submitting = true
        failure = nil
        defer { submitting = false }
        let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if action == .revision {
                try await model.requestRevision(taskId: taskId, feedback: reason)
            } else {
                try await model.failTask(taskId: taskId, reason: reason)
            }
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
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
                            .accessibilityIdentifier("job-detail-title")
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
        .refreshable { await model.refreshJobs() }
        .background(Theme.page.ignoresSafeArea())
        .navigationTitle("Pipeline")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if let job {
                ToolbarItem(placement: .topBarTrailing) {
                    PipelineMenu(job: job, popsOnDelete: true)
                }
            }
        }
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
            if let description = task.description, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(6)
                    .accessibilityIdentifier("task-description")
            }
            if !task.dependencies.isEmpty {
                Text("Waits for " + task.dependencies.joined(separator: ", "))
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
        .accessibilityIdentifier("task-row")
    }
}
