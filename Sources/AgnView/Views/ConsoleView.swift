import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScreenChrome(screen: .console, scrolls: false) {
            VStack(spacing: Theme.spacing) {
                Text(model.statusLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("status-line")
                AgentFilterChips()
                ConsoleLog()
                ConsoleComposer()
            }
            .padding(.bottom, 8)
        }
    }
}

private struct FilterChip: Identifiable {
    let id: String
    let title: String
    let value: String?
}

struct AgentFilterChips: View {
    @EnvironmentObject private var model: AppModel

    private let chips: [FilterChip] = [
        FilterChip(id: "all", title: "All", value: nil),
        FilterChip(id: "claude", title: "Claude", value: "claude_code"),
        FilterChip(id: "codex", title: "Codex", value: "codex"),
        FilterChip(id: "antigravity", title: "AntiGravity", value: "antigravity"),
        FilterChip(id: "deepseek", title: "DeepSeek", value: "deepseek"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips) { chip in
                    let selected = model.agentFilter == chip.value
                    Button {
                        model.setAgentFilter(chip.value)
                    } label: {
                        Text(chip.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? Color.white : Theme.textMain)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Theme.minTap)
                            .background(Capsule().fill(selected ? Theme.action : Theme.raised))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("chip-" + chip.id)
                }
            }
        }
    }
}

struct ConsoleLog: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.consoleLines) { line in
                        ConsoleRow(line: line).id(line.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { Keyboard.dismiss() })
            .onChange(of: model.consoleLines.last?.id) { _, newValue in
                if let newValue {
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
            }
            .onAppear {
                if let last = model.consoleLines.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border, lineWidth: 1))
        .overlay {
            if model.consoleLines.isEmpty {
                Text("Waiting for output")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("console-empty")
            }
        }
        .accessibilityIdentifier("console-log")
    }
}

struct ConsoleRow: View {
    let line: ConsoleLine

    private var tint: Color {
        switch line.agent {
        case "claude_code": return Theme.action
        case "codex": return Theme.success
        case "antigravity": return Theme.warning
        case "deepseek": return Theme.error
        default: return Theme.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.agentName(line.agent))
                .font(.caption.bold())
                .foregroundStyle(tint)
            Text(line.content)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.textMain)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("console-row")
    }
}

private struct AgentOption: Identifiable {
    let id: String
    let name: String
}

/// A rounded chip that shows a title and opens a menu. Used for Model and
/// Effort in the composer and in the keyboard toolbar.
struct ChipLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .imageScale(.small)
        }
        .foregroundStyle(Theme.textMain)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Capsule().fill(Theme.raised))
    }
}

/// A menu of options with a check mark on the chosen one. Options carry an
/// identifier of the form <prefix>-option-<id> so tests can pick one.
struct OptionMenu: View {
    let title: String
    let symbol: String
    let options: [ChoiceOption]
    let selectedId: String
    let identifier: String
    /// A line under the options, such as why the list holds Default only.
    var note: String? = nil
    let onSelect: (String) -> Void

    init(title: String, symbol: String, options: [ChoiceOption], selectedId: String,
         identifier: String, note: String? = nil, onSelect: @escaping (String) -> Void) {
        self.title = title
        self.symbol = symbol
        self.options = options
        self.selectedId = selectedId
        self.identifier = identifier
        self.note = note
        self.onSelect = onSelect
    }

    var body: some View {
        Menu {
            if let note {
                Section {
                    Text(note)
                        .accessibilityIdentifier(identifier + "-note")
                }
            }
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    if option.id == selectedId {
                        Label(option.name, systemImage: "checkmark")
                    } else {
                        Text(option.name)
                    }
                }
                .accessibilityIdentifier(identifier + "-option-" + (option.id.isEmpty ? "default" : option.id))
            }
        } label: {
            ChipLabel(title: title, symbol: symbol)
        }
        .accessibilityLabel(identifier.contains("effort") ? "Effort" : "Model")
        .accessibilityValue(title)
        .accessibilityIdentifier(identifier)
    }
}

struct ConsoleComposer: View {
    @EnvironmentObject private var model: AppModel

    @State private var selection = ComposerSelection()
    @State private var prompt = ""
    @State private var attachments: [AttachmentItem] = []
    @State private var showAttach = false
    @FocusState private var focused: Bool

    private let agents: [AgentOption] = [
        AgentOption(id: "claude_code", name: "Claude Code"),
        AgentOption(id: "codex", name: "Codex"),
        AgentOption(id: "antigravity", name: "AntiGravity"),
        AgentOption(id: "deepseek", name: "DeepSeek"),
    ]

    /// The room the floating keyboard bar needs. Older systems draw the bar
    /// inside the keyboard area, so they need none.
    static var keyboardBarClearance: CGFloat {
        if #available(iOS 26, *) { return 56 }
        return 0
    }

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sending: Bool { model.dispatchState?.isLoading ?? false }
    private var canSend: Bool { model.canDispatch && !trimmed.isEmpty && !sending }
    private var modelOptions: [ChoiceOption] { model.catalogue.modelOptions(for: selection.agent) }
    private var effortOptions: [ChoiceOption] { model.catalogue.effortOptions(for: selection.agent) }

    private func modelChip(_ prefix: String) -> some View {
        OptionMenu(title: ComposerSelection.chipText(modelOptions, selected: selection.modelId),
                   symbol: "cpu", options: modelOptions, selectedId: selection.modelId,
                   identifier: prefix + "-model",
                   note: model.modelMenuNote(for: selection.agent)) { selection.modelId = $0 }
    }

    private func effortChip(_ prefix: String) -> some View {
        OptionMenu(title: ComposerSelection.chipText(effortOptions, selected: selection.effortId),
                   symbol: "gauge.with.dots.needle.33percent", options: effortOptions,
                   selectedId: selection.effortId,
                   identifier: prefix + "-effort") { selection.effortId = $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = model.dispatchNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-notice")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(agents) { item in
                        let chosen = selection.agent == item.id
                        Button {
                            selection.select(agent: item.id, catalogue: model.catalogue)
                            Task { await model.refreshCatalogueIfMissing(for: item.id) }
                        } label: {
                            Text(item.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(chosen ? Color.white : Theme.textMain)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 36)
                                .background(Capsule().fill(chosen ? Theme.action : Theme.raised))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                        .accessibilityIdentifier("composer-agent-" + item.id)
                    }
                }
            }
            HStack(spacing: 8) {
                modelChip("composer")
                effortChip("composer")
                Button {
                    showAttach = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                        if !attachments.isEmpty { Text("\(attachments.count)").font(.subheadline.weight(.semibold)) }
                    }
                    .foregroundStyle(Theme.textMain)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(Theme.raised))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach")
                .accessibilityIdentifier("composer-attach")
                Spacer(minLength: 0)
            }
            if !attachments.isEmpty {
                AttachmentChips(items: $attachments, identifierPrefix: "composer")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: Theme.minTap)
                    .focused($focused)
                    .toolbar {
                        // Model and Effort on the left, Done on the right. The
                        // bar sits above the keyboard, so nothing covers Send.
                        ToolbarItemGroup(placement: .keyboard) {
                            modelChip("toolbar")
                            effortChip("toolbar")
                            Spacer()
                            Button("Done") {
                                focused = false
                                Keyboard.dismiss()
                            }
                            .accessibilityIdentifier("keyboard-done")
                        }
                    }
                    .accessibilityIdentifier("composer-prompt")
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.action)
                    .controlSize(.large)
                    .disabled(!canSend)
                    .accessibilityIdentifier("composer-send")
            }
            switch model.dispatchState {
            case .loaded(let response):
                Text(Self.replyText(response, fallbackAgent: selection.agent))
                    .font(.footnote)
                    .foregroundStyle(Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-result")
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-error")
            default:
                EmptyView()
            }
        }
        .disabled(!model.canDispatch)
        .card()
        // On iOS 26 the keyboard bar floats above the keyboard instead of
        // being part of it, so it would sit over Send. Lift the composer by
        // the height of the bar while the field has focus.
        .padding(.bottom, focused ? ConsoleComposer.keyboardBarClearance : 0)
        .animation(.easeOut(duration: 0.2), value: focused)
        .sheet(isPresented: $showAttach) {
            AttachSheet(attachments: $attachments)
                .environmentObject(model)
        }
    }

    /// The reply shown under the composer: status, agent, session id and the
    /// hub message, whichever the hub sent.
    static func replyText(_ response: DispatchResponse, fallbackAgent: String) -> String {
        var parts: [String] = []
        if let status = response.status, !status.isEmpty { parts.append("Status: \(status)") }
        parts.append("Agent: \(Format.agentName(response.agent ?? fallbackAgent))")
        if let session = response.sessionId, !session.isEmpty { parts.append("Session: \(Format.shortId(session))") }
        if let message = response.message, !message.isEmpty { parts.append(message) }
        return parts.joined(separator: "\n")
    }

    private func send() {
        let text = trimmed
        guard canSend else { return }
        let target = selection.agent
        let chosenModel = selection.modelValue
        let chosenEffort = selection.effortValue
        let paths = Attachments.hubPaths(attachments)
        Task {
            if await model.send(agent: target, prompt: text, model: chosenModel, effort: chosenEffort,
                                files: paths.isEmpty ? nil : paths) {
                prompt = ""
                attachments = []
            }
        }
    }
}
