import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel
    /// The agent, model and effort the composer will send with. It lives here
    /// so the empty state can name the chosen agent.
    @State private var selection = ComposerSelection()

    var body: some View {
        ScreenChrome(screen: .console) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ScreenBanners(inList: false)
                    Text(model.statusLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("status-line")
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.bottom, 4)
                ConsoleLog(agent: selection.agent)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        ConsoleComposer(selection: $selection)
                    }
            }
        }
    }
}

/// The conversation: your prompts as bubbles on the right, agent replies as
/// plain text on the left. It follows new output while you are at the bottom,
/// and the keyboard closes when you scroll, swipe down or tap the chat.
struct ConsoleLog: View {
    /// The agent the composer has chosen, for the empty state.
    let agent: String

    @EnvironmentObject private var model: AppModel
    @StateObject private var transcript = TranscriptModel()
    @State private var atBottom = true

    private static let bottomId = "console-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let lastId = transcript.items.last?.id
                    ForEach(transcript.items) { item in
                        ChatItemView(item: item, isLast: item.id == lastId, sessions: model.sessions)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomId)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, Theme.screenPadding)
                .padding(.top, 4)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded { Keyboard.dismiss() })
            .onReceive(model.$consoleLines) { transcript.update($0) }
            .onChange(of: transcript.revision) { _, _ in
                if atBottom { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
            .onAppear {
                transcript.update(model.consoleLines)
                DispatchQueue.main.async { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if transcript.items.isEmpty {
                EmptyChatView(agent: agent)
            }
        }
        .accessibilityIdentifier("console-log")
    }
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
    /// The small chip of the composer instead of the roomy chip of a form.
    var compact = false
    let onSelect: (String) -> Void

    init(title: String, symbol: String, options: [ChoiceOption], selectedId: String,
         identifier: String, note: String? = nil, fill: Bool = false, compact: Bool = false,
         onSelect: @escaping (String) -> Void) {
        self.title = title
        self.symbol = symbol
        self.options = options
        self.selectedId = selectedId
        self.identifier = identifier
        self.note = note
        self.fill = fill
        self.compact = compact
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
            if compact {
                ComposerChipLabel(title: title, symbol: symbol)
            } else {
                ChipLabel(title: title, symbol: symbol, fill: fill)
            }
        }
        // The options keep the order of the list, whatever is chosen and
        // wherever the menu opens.
        .menuOrder(.fixed)
        .accessibilityLabel(name)
        .accessibilityValue(title)
        .accessibilityIdentifier(identifier)
    }
}
