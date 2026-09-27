import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel
    /// The agent, model and effort the composer will send with. It lives here
    /// so the empty state can name the chosen agent.
    @State private var selection = ComposerSelection()

    var body: some View {
        ScreenChrome(screen: .console) {
            VStack(spacing: 0) {
                // The status block is a top inset of the chat: an opaque
                // block that the chat starts below. Text that scrolls up
                // never shows behind it, and a short fade under it hides a
                // half-cut line at the edge.
                ConsoleLog(agent: selection.agent)
                    .safeAreaInset(edge: .top, spacing: 0) { statusBlock }
                // The composer is a sibling under the chat, not an inset over
                // it, so a tap in the field can never reach the chat's tap.
                ConsoleComposer(selection: $selection)
            }
        }
    }

    private var statusBlock: some View {
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
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background(Theme.chatBackground)
        .overlay(alignment: .bottom) {
            // Solid for the first stretch, so a cut line is hidden, then a soft fade.
            LinearGradient(stops: [.init(color: Theme.chatBackground, location: 0),
                                   .init(color: Theme.chatBackground, location: 0.5),
                                   .init(color: Theme.chatBackground.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 44)
                .offset(y: 44)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .zIndex(1)
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
    @State private var pinnedForKeyboard = false

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
                // Room under the status fade, so the first line is never washed out.
                .padding(.top, 24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            // Keeps the newest message in place when the chat resizes, as it
            // does when the keyboard opens.
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(TapGesture().onEnded { Keyboard.dismiss() })
            .onReceive(model.$consoleLines) { transcript.update($0, demo: model.isDemo) }
            // The keyboard shrinks the chat. When you were at the bottom, stay there,
            // so the newest message stays above the composer.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                pinnedForKeyboard = atBottom
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard pinnedForKeyboard else { return }
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    pinnedForKeyboard = false
                }
            }
            .onChange(of: transcript.revision) { _, _ in
                if atBottom { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
            .onAppear {
                transcript.update(model.consoleLines, demo: model.isDemo)
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
