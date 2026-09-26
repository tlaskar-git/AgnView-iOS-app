import SwiftUI
import UIKit

/// Places one child at the trailing edge and gives it at most a fraction of
/// the row, so a long prompt wraps at about 80 percent of the width and a
/// short one hugs its text.
struct TrailingFractionLayout: Layout {
    var fraction: CGFloat = 0.8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let inner = subview.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 * fraction },
                                                          height: nil))
        return CGSize(width: proposal.width ?? inner.width, height: inner.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let inner = subview.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        subview.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                      proposal: ProposedViewSize(width: inner.width, height: inner.height))
    }
}

/// What the user sent: a soft rounded bubble on the right.
struct UserBubble: View {
    let text: String

    var body: some View {
        TrailingFractionLayout(fraction: 0.8) {
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.bubbleText)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.bubble))
                .accessibilityLabel("You: " + text)
                .accessibilityIdentifier("console-row")
        }
        .padding(.top, 16)
        .padding(.bottom, 6)
    }
}

/// A small pulsing dot at the end of a reply that is still being written.
struct StreamingDot: View {
    let color: Color

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .scaleEffect(pulse ? 0.72 : 1)
            .opacity(pulse ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .accessibilityLabel("Answering")
            .accessibilityIdentifier("console-streaming")
    }
}

/// A fenced code block: a language label, a Copy button and code that scrolls
/// sideways when a line is long.
struct CodeBlockView: View {
    let language: String
    let source: String

    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(ChatCode.displayName(language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = source
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_400_000_000)
                        copied = false
                    }
                } label: {
                    Text(copied ? "Copied" : "Copy")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.link)
                        .frame(minWidth: 60, minHeight: Theme.minTap, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "Copied" : "Copy code")
                .accessibilityIdentifier("code-copy")
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .frame(height: 36)
            .background(Theme.codeHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(source)
                    .font(.system(.footnote, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.codeText)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .textSelection(.enabled)
            }
        }
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.codeLine, lineWidth: 1))
        .padding(.top, 8)
        .padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-block")
    }
}

/// An agent reply: a small label (a coloured dot and the name) and plain
/// serif text with no bubble. Code fences become code blocks.
struct AgentReplyView: View {
    let reply: ChatReply
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.agentColor(reply.agent))
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(reply.agentName)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(Array(reply.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(text)
                        .font(.system(.body, design: .serif))
                        .lineSpacing(5)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel(text)
                        .accessibilityIdentifier("console-row")
                case .code(let language, let source):
                    CodeBlockView(language: language, source: source)
                }
            }
            if streaming {
                StreamingDot(color: Theme.agentColor(reply.agent))
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 22)
        .padding(.bottom, 10)
    }
}

/// One item of the conversation.
struct ChatItemView: View {
    let item: ChatItem
    let isLast: Bool
    let sessions: [SessionInfo]

    private func session(for reply: ChatReply) -> SessionInfo? {
        guard let id = reply.sessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var body: some View {
        switch item {
        case .separator(_, let text):
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .accessibilityIdentifier("console-time")
        case .system(_, let text):
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityIdentifier("console-system")
        case .user(_, let text):
            UserBubble(text: text)
        case .agent(let reply):
            if isLast {
                // Only the last reply can be streaming. The clock ticks once a
                // second so the dot goes away when the lines stop.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    AgentReplyView(
                        reply: reply,
                        streaming: ChatStreaming.isStreaming(lastLineTime: reply.lastLineTime,
                                                             now: context.date, isLastItem: true,
                                                             session: session(for: reply)))
                }
            } else {
                AgentReplyView(reply: reply, streaming: false)
            }
        }
    }
}

/// Keeps the conversation built from the console lines. It reads only the new
/// lines each time.
@MainActor
final class TranscriptModel: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    /// Grows with every change, so a view can react to a reply that got longer.
    @Published private(set) var revision = 0

    private var builder = ChatBuilder()

    func update(_ lines: [ConsoleLine]) {
        if builder.sync(lines) {
            items = builder.items
            revision += 1
        }
    }
}

/// The screen when nothing was said yet.
struct EmptyChatView: View {
    let agent: String

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(Theme.agentColor(agent))
                .frame(width: 14, height: 14)
                .padding(.bottom, 10)
                .accessibilityHidden(true)
            Text("What should " + Format.agentName(agent) + " work on?")
                .font(.system(.title, design: .serif))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
            Text("Write a message below, or attach files with the plus button.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("console-empty")
    }
}
