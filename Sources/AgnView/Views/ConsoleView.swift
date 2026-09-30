import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject private var model: AppModel
    /// The agent, model and effort the composer will send with. It lives here
    /// so the empty state can name the chosen agent.
    @State private var selection = ComposerSelection()

    var body: some View {
        ScreenChrome(screen: .console) {
            VStack(spacing: 0) {
                statusBlock
                ConsoleLog(agent: selection.agent)
                // The composer is a sibling under the chat, not an inset over
                // it, so a tap in the field can never reach the chat's tap.
                ConsoleComposer(selection: $selection)
            }
        }
    }

    /// An opaque block above the chat, so the scrolling text underneath never
    /// shows a half-cut line through or behind it.
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
        .padding(.bottom, 10)
        .background(Theme.chatBackground)
    }
}

/// The conversation: your prompts as bubbles on the right, agent replies as
/// plain text on the left. It follows new output while you are at the bottom,
/// and the keyboard closes when you scroll, swipe down or tap the chat.
///
/// Following new output: the chat follows until the reader scrolls away from
/// the bottom, and follows again when the reader comes back or sends a
/// prompt. New rows never stop it. Before 1.0.7 the chat stopped following
/// when a burst of new rows (a reply is three or four rows at once) pushed a
/// one-point marker at the bottom off screen before the scroll caught up, and
/// the scroll ran before the new rows were laid out. The reply then sat below
/// the fold, so a prompt looked as if nothing came back. On iOS 18 and later
/// the chat now scrolls when the content has grown (after layout), and only
/// a drag or a fling by the reader can stop it following.
struct ConsoleLog: View {
    /// The agent the composer has chosen, for the empty state.
    let agent: String

    @EnvironmentObject private var model: AppModel
    @StateObject private var transcript = TranscriptModel()
    /// True while the chat follows new output.
    @State private var following = true
    @State private var pinnedForKeyboard = false

    private static let bottomId = "console-bottom"
    /// How close to the bottom counts as at the bottom, in points.
    private static let bottomSlack: CGFloat = 48

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
                        .onAppear { setFollowing(true, "bottom on screen") }
                        .onDisappear {
                            // iOS 17 only: it has no scroll phase, so a marker
                            // that leaves within a second of new rows is taken
                            // as the rows, not the reader.
                            guard !ChatScrollTracker.isAvailable,
                                  Date().timeIntervalSince(transcript.lastChange) > 1 else { return }
                            setFollowing(false, "bottom left the screen (iOS 17)")
                        }
                }
                .padding(.horizontal, Theme.screenPadding)
                // A clear gap below the status block, so the topmost visible
                // row of a scrolled chat is never flush against it.
                .padding(.top, 14)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            // Keeps the newest message in place when the chat resizes, as it
            // does when the keyboard opens.
            .defaultScrollAnchor(.bottom)
            .modifier(ChatScrollTracker(slack: Self.bottomSlack) { event in
                switch event {
                case .contentGrew:
                    if following { scrollToBottom(proxy, "content grew") }
                case .readerMoved(let atBottom):
                    setFollowing(atBottom, atBottom ? "reader at the bottom" : "reader scrolled away")
                case .settledAtBottom:
                    setFollowing(true, "settled at the bottom")
                }
            })
            .simultaneousGesture(TapGesture().onEnded { Keyboard.dismiss() })
            .onReceive(model.$consoleLines) { lines in
                guard transcript.update(lines, demo: model.isDemo) else { return }
                // iOS 18 and later scroll when the content size changes (see
                // ChatScrollTracker). iOS 17 scrolls here, once per update.
                if !ChatScrollTracker.isAvailable, following { scrollToBottom(proxy, "new rows (iOS 17)") }
            }
            // The keyboard shrinks the chat. When you were at the bottom, stay there,
            // so the newest message stays above the composer.
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                pinnedForKeyboard = following
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                guard pinnedForKeyboard else { return }
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    proxy.scrollTo(Self.bottomId, anchor: .bottom)
                    pinnedForKeyboard = false
                }
            }
            // Sending a prompt always brings the chat back to the bottom, so
            // the prompt and its reply are on screen.
            .onChange(of: model.dispatchState?.isLoading ?? false) { _, sending in
                guard sending else { return }
                setFollowing(true, "prompt sent")
                scrollToBottom(proxy, "prompt sent")
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

    private func setFollowing(_ value: Bool, _ reason: String) {
        guard following != value else { return }
        following = value
        HubLog.event("console following \(value): \(reason)")
    }

    /// Scrolls now, and once more on the next turn of the main queue, after
    /// any rows added in this update are laid out.
    private func scrollToBottom(_ proxy: ScrollViewProxy, _ reason: String) {
        HubLog.event("console scroll to bottom: \(reason)")
        proxy.scrollTo(Self.bottomId, anchor: .bottom)
        DispatchQueue.main.async { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
    }
}

/// Watches a scroll view on iOS 18 and later: when its content grows, and
/// where the reader leaves it. Does nothing on iOS 17.
struct ChatScrollTracker: ViewModifier {
    enum Event {
        /// The content got taller, after layout.
        case contentGrew
        /// The reader dragged or flung the chat. True when it is near the bottom.
        case readerMoved(atBottom: Bool)
        /// The chat is at the bottom without the reader touching it.
        case settledAtBottom
    }

    let slack: CGFloat
    let onEvent: (Event) -> Void

    static var isAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.modifier(ChatScrollTracker18(slack: slack, onEvent: onEvent))
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct ChatScrollTracker18: ViewModifier {
    let slack: CGFloat
    let onEvent: (ChatScrollTracker.Event) -> Void

    @State private var readerScrolling = false

    private struct Metrics: Equatable {
        var contentHeight: CGFloat
        /// How far the bottom of the content is below the bottom of the view.
        var distanceToBottom: CGFloat
    }

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                readerScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
            }
            .onScrollGeometryChange(for: Metrics.self) { geometry in
                let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
                let contentBottom = geometry.contentSize.height + geometry.contentInsets.bottom
                return Metrics(contentHeight: geometry.contentSize.height,
                               distanceToBottom: contentBottom - visibleBottom)
            } action: { old, new in
                let atBottom = new.distanceToBottom <= slack
                if new.contentHeight > old.contentHeight + 0.5 {
                    onEvent(.contentGrew)
                } else if readerScrolling {
                    onEvent(.readerMoved(atBottom: atBottom))
                } else if atBottom {
                    onEvent(.settledAtBottom)
                }
            }
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
