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
    }
}

private struct AgentOption: Identifiable {
    let id: String
    let name: String
}

struct ConsoleComposer: View {
    @EnvironmentObject private var model: AppModel

    @State private var agent = "claude_code"
    @State private var prompt = ""
    @State private var sending = false
    @State private var resultText: String?
    @State private var errorText: String?

    private let agents: [AgentOption] = [
        AgentOption(id: "claude_code", name: "Claude Code"),
        AgentOption(id: "codex", name: "Codex"),
        AgentOption(id: "antigravity", name: "AntiGravity"),
        AgentOption(id: "deepseek", name: "DeepSeek"),
    ]

    private var trimmed: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { model.canDispatch && !trimmed.isEmpty && !sending }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = model.dispatchNotice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer-notice")
            }
            HStack {
                Text("Send to")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Picker("Agent", selection: $agent) {
                    ForEach(agents) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("composer-agent")
                Spacer()
            }
            HStack(alignment: .center, spacing: 8) {
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: Theme.minTap)
                    .accessibilityIdentifier("composer-prompt")
                Button("Send") { send() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.action)
                    .controlSize(.large)
                    .disabled(!canSend)
                    .accessibilityIdentifier("composer-send")
            }
            if let resultText {
                Text(resultText)
                    .font(.footnote)
                    .foregroundStyle(Theme.success)
                    .accessibilityIdentifier("composer-result")
            }
            if let errorText {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(Theme.error)
                    .accessibilityIdentifier("composer-error")
            }
        }
        .disabled(!model.canDispatch)
        .card()
    }

    private func send() {
        let text = trimmed
        guard canSend else { return }
        sending = true
        resultText = nil
        errorText = nil
        let target = agent
        Task {
            do {
                let response = try await model.dispatch(agent: target, prompt: text)
                resultText = response.message ?? "Sent to \(Format.agentName(target))."
                prompt = ""
            } catch {
                errorText = error.localizedDescription
            }
            sending = false
        }
    }
}
