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
struct ConsoleLog: View {
    /// The agent the composer has chosen, for the empty state.
    let agent: String

    @EnvironmentObject private var model: AppModel
    @StateObject private var transcript = TranscriptModel()
    /// True while the chat follows new output. Only the reader turns it off,
    /// by scrolling away from the bottom. New rows never turn it off: a row
    /// pushes the bottom marker off screen before the scroll catches up, and
    /// that must not stop the chat from following (the newest reply then
    /// stayed below the fold and never showed).
    @State private var following = true
    /// True while the reader drags or flings the chat (iOS 18 and later).
    @State private var readerScrolling = false
    /// When the transcript last grew. On iOS 17, which cannot tell a drag
    /// from a scroll caused by new rows, a marker that leaves the screen
    /// within a second of new rows does not count as the reader scrolling.
    @State private var lastGrowth = Date.distantPast
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
                        .onAppear { following = true }
                        .onDisappear {
                            if readerScrolling
                                || (!ScrollPhaseTracker.isAvailable && Date().timeIntervalSince(lastGrowth) > 1) {
                                following = false
                            }
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
            .modifier(ScrollPhaseTracker(readerScrolling: $readerScrolling))
            .simultaneousGesture(TapGesture().onEnded { Keyboard.dismiss() })
            .onReceive(model.$consoleLines) { transcript.update($0, demo: model.isDemo) }
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
            .onChange(of: transcript.revision) { _, _ in
                lastGrowth = Date()
                guard following else { return }
                scrollToBottom(proxy)
            }
            // Sending a prompt always brings the chat back to the bottom, so
            // the prompt and its reply are on screen.
            .onChange(of: model.dispatchState?.isLoading ?? false) { _, sending in
                guard sending else { return }
                following = true
                scrollToBottom(proxy)
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

    /// Scrolls now, and once more after the new rows are laid out: a scroll
    /// made in the same update as the new rows can stop short of them.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomId, anchor: .bottom)
        DispatchQueue.main.async { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
    }
}

/// Tells whether the reader is dragging or flinging a scroll view. iOS 18
/// and later report the scroll phase. iOS 17 does not, and there the flag
/// stays false (see ConsoleLog.lastGrowth for the fallback).
struct ScrollPhaseTracker: ViewModifier {
    @Binding var readerScrolling: Bool

    static var isAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                readerScrolling = phase == .interacting || phase == .decelerating
            }
        } else {
            content
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
