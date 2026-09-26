import SwiftUI

/// The full-height New pipeline sheet.
struct NewPipelineView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Called with the created pipeline, after the sheet closes.
    let onCreated: (Job) -> Void

    @State private var draft = PipelineDraft()
    @State private var submitting = false
    @State private var rejection: String?
    @State private var showIssues = false
    @State private var showAttach = false
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.pipelineCreateNotice {
                        Banner(kind: .warning, text: notice, identifier: "np-notice")
                    }
                    detailsSection
                    attachSection
                    tasksSection
                    issuesSection
                }
                .padding(Theme.screenPadding)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("New pipeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft.isDirty { confirmDiscard = true } else { dismiss() }
                    }
                    .accessibilityIdentifier("np-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if submitting { ProgressView() } else { Text("Create") }
                    }
                    .disabled(submitting || !model.canManageJobs)
                    .accessibilityIdentifier("np-create")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { Keyboard.dismiss() }
                        .accessibilityIdentifier("np-keyboard-done")
                }
            }
            .confirmationDialog("Discard this pipeline?", isPresented: $confirmDiscard,
                                titleVisibility: .visible) {
                Button("Discard", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("What you entered is lost.")
            }
            .sheet(isPresented: $showAttach) {
                AttachSheet(attachments: $draft.attachments)
                    .environmentObject(model)
            }
        }
        .presentationDetents([.large])
        .modifier(FullHeightSheet())
        .interactiveDismissDisabled(draft.isDirty)
        .accessibilityIdentifier("new-pipeline")
    }

    // MARK: Sections

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FormLabel("Pipeline ID (optional)")
            TextField("Leave empty to let the hub pick one", text: $draft.jobId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("np-id")
            FormLabel("Title")
            TextField("Title", text: $draft.title)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("np-title")
            FormLabel("Description")
            TextField("Description", text: $draft.description, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("np-description")
        }
    }

    private var attachSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormLabel("Files")
            Text("Each task gets the attached files added to its description.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
            Button {
                showAttach = true
            } label: {
                Label("Attach", systemImage: "paperclip")
                    .frame(minHeight: Theme.minTap)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("np-attach")
            if !draft.attachments.isEmpty {
                AttachmentChips(items: $draft.attachments, identifierPrefix: "np")
            }
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            FormLabel("Tasks")
            ForEach(Array(draft.tasks.enumerated()), id: \.element.id) { index, task in
                taskCard(index: index, task: task)
            }
            Button {
                draft.addTask()
            } label: {
                Label("Add task", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: Theme.minTap)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("np-add-task")
        }
    }

    @ViewBuilder
    private var issuesSection: some View {
        let issues = draft.issues()
        // A cycle is shown at once. The other issues wait for the first Create tap.
        let shown = issues.filter { showIssues || isCycle($0) }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, issue in
                    Text(issue.message)
                        .font(.footnote)
                        .foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("np-issues")
        }
        if let rejection {
            Banner(kind: .error, text: rejection, identifier: "np-error")
        }
    }

    private func isCycle(_ issue: PipelineIssue) -> Bool {
        if case .dependencyCycle = issue { return true }
        return false
    }

    // MARK: Task card

    private func binding(for id: UUID) -> Binding<TaskDraft> {
        Binding(
            get: { draft.tasks.first { $0.id == id } ?? TaskDraft(id: id, taskId: "") },
            set: { updated in
                if let index = draft.tasks.firstIndex(where: { $0.id == id }) { draft.tasks[index] = updated }
            })
    }

    private func taskCard(index: Int, task: TaskDraft) -> some View {
        let taskBinding = binding(for: task.id)
        let choices = draft.prerequisiteChoices(for: task.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Task \(index + 1)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textMain)
                Spacer()
                Button(role: .destructive) {
                    draft.removeTask(task.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.subheadline)
                        .frame(minHeight: Theme.minTap)
                }
                .disabled(draft.tasks.count <= 1)
                .accessibilityIdentifier("np-task-remove")
            }
            FormLabel("Task ID")
            TextField("Task ID", text: taskBinding.taskId)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("np-task-id")
            FormLabel("Title")
            TextField("Task title", text: taskBinding.title)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("np-task-title")
            FormLabel("Description")
            TextField("Task description", text: taskBinding.description, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("np-task-description")
            HStack(spacing: 8) {
                agentMenu(taskBinding)
                prerequisiteMenu(taskBinding, choices: choices)
            }
            if model.features.supportsTaskModelEffort {
                HStack(spacing: 8) {
                    OptionMenu(title: ComposerSelection.chipText(model.catalogue.modelOptions(for: task.agent),
                                                                  selected: task.modelId),
                               symbol: "cpu", options: model.catalogue.modelOptions(for: task.agent),
                               selectedId: task.modelId, identifier: "np-task-model") { taskBinding.wrappedValue.modelId = $0 }
                    OptionMenu(title: ComposerSelection.chipText(model.catalogue.effortOptions(for: task.agent),
                                                                  selected: task.effortId),
                               symbol: "gauge.with.dots.needle.33percent",
                               options: model.catalogue.effortOptions(for: task.agent),
                               selectedId: task.effortId, identifier: "np-task-effort") { taskBinding.wrappedValue.effortId = $0 }
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-task")
    }

    private func agentMenu(_ task: Binding<TaskDraft>) -> some View {
        let current = PipelineDraft.agents.first { $0.id == task.wrappedValue.agent }?.name ?? task.wrappedValue.agent
        return Menu {
            ForEach(PipelineDraft.agents) { agent in
                Button {
                    var value = task.wrappedValue
                    value.agent = agent.id
                    value.modelId = ""
                    value.effortId = ""
                    task.wrappedValue = value
                } label: {
                    if agent.id == task.wrappedValue.agent {
                        Label(agent.name, systemImage: "checkmark")
                    } else {
                        Text(agent.name)
                    }
                }
                .accessibilityIdentifier("np-task-agent-option-" + agent.id)
            }
        } label: {
            ChipLabel(title: current, symbol: "person.crop.circle")
        }
        .accessibilityLabel("Agent")
        .accessibilityValue(current)
        .accessibilityIdentifier("np-task-agent")
    }

    private func prerequisiteMenu(_ task: Binding<TaskDraft>, choices: [TaskDraft]) -> some View {
        let names = choices.filter { task.wrappedValue.prerequisites.contains($0.id) }
            .map { $0.taskId.isEmpty ? "(no id)" : $0.taskId }
        let title = names.isEmpty ? "No prerequisites" : names.joined(separator: ", ")
        return Menu {
            if choices.isEmpty {
                Text("Add another task first")
            }
            ForEach(choices) { other in
                Button {
                    var value = task.wrappedValue
                    if value.prerequisites.contains(other.id) {
                        value.prerequisites.remove(other.id)
                    } else {
                        value.prerequisites.insert(other.id)
                    }
                    task.wrappedValue = value
                } label: {
                    if task.wrappedValue.prerequisites.contains(other.id) {
                        Label(other.taskId.isEmpty ? "(no id)" : other.taskId, systemImage: "checkmark")
                    } else {
                        Text(other.taskId.isEmpty ? "(no id)" : other.taskId)
                    }
                }
            }
        } label: {
            ChipLabel(title: title, symbol: "arrow.triangle.branch")
        }
        .accessibilityLabel("Prerequisites")
        .accessibilityValue(title)
        .accessibilityIdentifier("np-task-prereq")
    }

    // MARK: Create

    private func create() async {
        rejection = nil
        guard draft.isValid else {
            showIssues = true
            return
        }
        submitting = true
        defer { submitting = false }
        do {
            let job = try await model.createPipeline(draft)
            dismiss()
            onCreated(job)
        } catch {
            rejection = error.localizedDescription
        }
    }
}

private struct FormLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Makes a sheet fill the screen height on iPad, where a sheet is a narrow
/// form by default. iPhone sheets are full height already.
struct FullHeightSheet: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}
