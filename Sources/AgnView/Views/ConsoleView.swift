import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScreenChrome(screen: .console, trailing: { AgentFilterMenu() }) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ScreenBanners(inList: false)
                    Text(model.statusLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("status-line")
                    if let name = AgentFilterMenu.title(for: model.agentFilter), model.agentFilter != nil {
                        Text("Showing " + name + " only")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("filter-summary")
                    }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 8)
                ConsoleLog()
                ConsoleComposer()
            }
            .background(Theme.page.ignoresSafeArea())
        }
    }
}

private struct FilterOption: Identifiable {
    let id: String
    let title: String
    let value: String?
}

/// The agent filter as a menu in the navigation bar. A menu has room for every
/// name in full, so AntiGravity and DeepSeek never clip.
struct AgentFilterMenu: View {
    @EnvironmentObject private var model: AppModel

    private static let options: [FilterOption] = [
        FilterOption(id: "all", title: "All agents", value: nil),
        FilterOption(id: "claude", title: "Claude", value: "claude_code"),
        FilterOption(id: "codex", title: "Codex", value: "codex"),
        FilterOption(id: "antigravity", title: "AntiGravity", value: "antigravity"),
        FilterOption(id: "deepseek", title: "DeepSeek", value: "deepseek"),
    ]

    /// The menu title for a filter value, or nil when the value is unknown.
    static func title(for value: String?) -> String? {
        options.first { $0.value == value }?.title
    }

    private var selection: Binding<String> {
        Binding(get: { model.agentFilter ?? "" },
                set: { model.setAgentFilter($0.isEmpty ? nil : $0) })
    }

    var body: some View {
        Menu {
            Picker("Agent", selection: selection) {
                ForEach(Self.options) { option in
                    Text(option.title)
                        .tag(option.value ?? "")
                        .accessibilityIdentifier("filter-option-" + option.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: model.agentFilter == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
                .frame(minWidth: Theme.minTap - 8, minHeight: Theme.minTap - 8)
        }
        .accessibilityLabel("Filter by agent")
        .accessibilityValue(Self.title(for: model.agentFilter) ?? "All agents")
        .accessibilityIdentifier("console-filter")
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
        .background(Theme.surface)
        .overlay {
            if model.consoleLines.isEmpty {
                ContentUnavailableView("Waiting for output", systemImage: "text.alignleft")
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
        case "claude_code": return Theme.link
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
/// Effort in the composer and in the keyboard toolbar. The title wraps to a
/// second line instead of clipping.
struct ChipLabel: View {
    let title: String
    let symbol: String
    /// True to take the width the row offers, so chips in a row share it.
    var fill = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if fill { Spacer(minLength: 0) }
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .foregroundStyle(Theme.textSecondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: fill ? Theme.minTap : 40)
        .background(Capsule().fill(Theme.raised))
    }
}

/// A menu with a Picker: the chosen option carries the check mark. Options
/// carry an identifier of the form <prefix>-option-<id> so tests can pick one.
struct OptionMenu: View {
    let title: String
    let symbol: String
    let options: [ChoiceOption]
    let selectedId: String
    let identifier: String
    /// A line above the options, such as why the list holds Default only.
    var note: String? = nil
    var fill = false
    let onSelect: (String) -> Void

    init(title: String, symbol: String, options: [ChoiceOption], selectedId: String,
         identifier: String, note: String? = nil, fill: Bool = false,
         onSelect: @escaping (String) -> Void) {
        self.title = title
        self.symbol = symbol
        self.options = options
        self.selectedId = selectedId
        self.identifier = identifier
        self.note = note
        self.fill = fill
        self.onSelect = onSelect
    }

    private var name: String { identifier.contains("effort") ? "Effort" : "Model" }

    var body: some View {
        Menu {
            if let note {
                Section {
                    Text(note)
                        .accessibilityIdentifier(identifier + "-note")
                }
            }
            Picker(name, selection: Binding(get: { selectedId }, set: { onSelect($0) })) {
                ForEach(options) { option in
                    Text(option.name)
                        .tag(option.id)
                        .accessibilityIdentifier(identifier + "-option-" + (option.id.isEmpty ? "default" : option.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(title: title, symbol: symbol, fill: fill)
        }
        .accessibilityLabel(name)
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
    private var agentName: String {
        agents.first { $0.id == selection.agent }?.name ?? selection.agent
    }

    private func modelChip(_ prefix: String, fill: Bool = false) -> some View {
        OptionMenu(title: ComposerSelection.chipText(modelOptions, selected: selection.modelId),
                   symbol: "cpu", options: modelOptions, selectedId: selection.modelId,
                   identifier: prefix + "-model",
                   note: model.modelMenuNote(for: selection.agent), fill: fill) { selection.modelId = $0 }
    }

    private func effortChip(_ prefix: String, fill: Bool = false) -> some View {
        OptionMenu(title: ComposerSelection.chipText(effortOptions, selected: selection.effortId),
                   symbol: "gauge.with.dots.needle.33percent", options: effortOptions,
                   selectedId: selection.effortId,
                   identifier: prefix + "-effort", fill: fill) { selection.effortId = $0 }
    }

    /// Choosing an agent resets Model and Effort when the new agent lacks them.
    private var agentBinding: Binding<String> {
        Binding(get: { selection.agent },
                set: { newAgent in
                    selection.select(agent: newAgent, catalogue: model.catalogue)
                    Task { await model.refreshCatalogueIfMissing(for: newAgent) }
                })
    }

    private var agentMenu: some View {
        Menu {
            Picker("Agent", selection: agentBinding) {
                ForEach(agents) { item in
                    Text(item.name)
                        .tag(item.id)
                        .accessibilityIdentifier("composer-agent-option-" + item.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChipLabel(title: agentName, symbol: "sparkles", fill: true)
        }
        .accessibilityLabel("Agent")
        .accessibilityValue(agentName)
        .accessibilityIdentifier("composer-agent")
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
            HStack(spacing: 8) {
                agentMenu
                Button {
                    showAttach = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                        if !attachments.isEmpty { Text("\(attachments.count)").font(.subheadline.weight(.semibold)) }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
                    .background(Capsule().fill(Theme.raised))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Attach")
                .accessibilityIdentifier("composer-attach")
            }
            HStack(spacing: 8) {
                modelChip("composer", fill: true)
                effortChip("composer", fill: true)
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
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
