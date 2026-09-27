import SwiftUI

struct AgentOption: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The agents in the composer menu. The order is fixed: it never follows the
/// selection, so the chosen agent does not jump to the top or the bottom.
enum ComposerAgents {
    static let all: [AgentOption] = [
        AgentOption(id: "claude_code", name: "Claude Code"),
        AgentOption(id: "codex", name: "Codex"),
        AgentOption(id: "antigravity", name: "AntiGravity"),
        AgentOption(id: "deepseek", name: "DeepSeek"),
    ]

    static func name(for id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}

/// The small chip in the composer: an agent dot or an icon, a name that
/// shortens with an ellipsis, and a chevron. 32 pt high inside a 44 pt target.
struct ComposerChipLabel: View {
    let title: String
    var symbol: String?
    var dot: Color?

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            } else if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.55)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .frame(minHeight: 32)
        .background(Capsule().fill(Theme.chipFill))
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// The floating composer: three chips (Agent, Model, Effort) in a fixed order,
/// then Attach, the text field and Send. It sits above the keyboard or the
/// tab bar. There is no keyboard toolbar: the chat closes the keyboard.
struct ConsoleComposer: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: ComposerSelection

    @State private var prompt = ""
    @State private var attachments: [AttachmentItem] = []
    @State private var showAttach = false
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sending: Bool { model.dispatchState?.isLoading ?? false }
    private var canSend: Bool { model.canDispatch && !trimmed.isEmpty && !sending }
    private var modelOptions: [ChoiceOption] { model.catalogue.modelOptions(for: selection.agent) }
    private var effortOptions: [ChoiceOption] { model.catalogue.effortOptions(for: selection.agent) }
    private var agentName: String { ComposerAgents.name(for: selection.agent) }

    // MARK: Chips

    private var modelChip: some View {
        OptionMenu(title: ComposerSelection.chipText(modelOptions, selected: selection.modelId),
                   symbol: "cpu", options: modelOptions, selectedId: selection.modelId,
                   identifier: "composer-model",
                   note: model.modelMenuNote(for: selection.agent), compact: true) {
            selection.modelId = $0
        }
    }

    private var effortChip: some View {
        OptionMenu(title: ComposerSelection.chipText(effortOptions, selected: selection.effortId),
                   symbol: "gauge.with.dots.needle.33percent", options: effortOptions,
                   selectedId: selection.effortId,
                   identifier: "composer-effort", compact: true) {
            selection.effortId = $0
        }
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
                ForEach(ComposerAgents.all) { item in
                    Text(item.name)
                        .tag(item.id)
                        .accessibilityIdentifier("composer-agent-option-" + item.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ComposerChipLabel(title: agentName, dot: Theme.agentColor(selection.agent))
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Agent")
        .accessibilityValue(agentName)
        .accessibilityIdentifier("composer-agent")
    }

    private var chipRow: some View {
        HStack(spacing: 6) {
            if typeSize.isAccessibilitySize {
                agentMenu
            } else {
                agentMenu.fixedSize(horizontal: true, vertical: false)
            }
            modelChip
                .frame(maxWidth: .infinity, alignment: .leading)
            effortChip
                .layoutPriority(1)
        }
    }

    // MARK: Input row

    private var attachButton: some View {
        Button {
            showAttach = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.chipFill))
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach")
        .accessibilityValue(attachments.isEmpty ? "" : "\(attachments.count) attached")
        .accessibilityIdentifier("composer-attach")
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(canSend ? Color.white : Theme.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(canSend ? Theme.accentFill : Theme.chipFill))
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("composer-send")
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 2) {
            attachButton
            // Return adds a line. Send is the button.
            TextField("Message " + agentName, text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 4)
                .padding(.vertical, 7)
                .frame(minHeight: 44)
                .focused($focused)
                .accessibilityIdentifier("composer-prompt")
            sendButton
        }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = model.dispatchNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("composer-notice")
            }
            chipRow
            if !attachments.isEmpty {
                AttachmentChips(items: $attachments, identifierPrefix: "composer")
                    .padding(.bottom, 2)
            }
            inputRow
            switch model.dispatchState {
            case .loaded(let response):
                Text(Self.replyText(response, fallbackAgent: selection.agent))
                    .font(.footnote)
                    .foregroundStyle(Theme.success)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("composer-result")
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("composer-error")
            default:
                EmptyView()
            }
        }
        .disabled(!model.canDispatch)
        .padding(.top, 6)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
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
