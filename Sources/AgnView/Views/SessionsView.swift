import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: NavState
    @State private var refreshing = false

    var body: some View {
        ScreenChrome(screen: .sessions, onRefresh: { await model.refreshSessionsNow() }) {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .center) {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(Format.updated(from: model.sessionsUpdatedAt, to: context.date))
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .accessibilityIdentifier("sessions-updated")
                    }
                    Spacer()
                    PillButton(title: "Refresh", symbol: "arrow.clockwise",
                               identifier: "sessions-refresh", busy: refreshing) {
                        Task {
                            refreshing = true
                            await model.refreshSessionsNow()
                            refreshing = false
                        }
                    }
                }
                if let notice = model.sessionsNotice {
                    Banner(kind: .info, text: notice, identifier: "sessions-notice")
                }
                if let message = model.sessionsState.failureMessage {
                    PanelErrorCard(message: message, prefix: "sessions") {
                        Task { await model.retrySessions() }
                    }
                }
                if model.sessions.isEmpty {
                    Text("No sessions yet.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                        .accessibilityIdentifier("sessions-empty")
                } else {
                    ForEach(model.sessions) { session in
                        Button {
                            model.setAgentFilter(session.agent)
                            nav.screen = .console
                        } label: {
                            SessionRow(session: session, firstLine: firstLine(for: session))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the console for this agent")
                        .accessibilityIdentifier("session-row")
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .task(id: model.connection.isOnline) {
            while !Task.isCancelled {
                await model.refreshSessions()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func firstLine(for session: SessionInfo) -> String {
        if let line = model.consoleLines.first(where: { $0.sessionId == session.id }) {
            return line.content
        }
        if let dir = session.workingDirectory, !dir.isEmpty {
            return (dir as NSString).lastPathComponent
        }
        return "Session " + Format.shortId(session.id)
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let firstLine: String

    private var age: String? {
        if let idle = session.idleSeconds { return Format.age(seconds: idle) }
        if let stamp = session.lastActivity, let date = ISO8601DateFormatter().date(from: stamp) {
            return Format.age(from: date, to: Date())
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Format.agentName(session.agent ?? ""))
                    .font(.headline)
                    .foregroundStyle(Theme.textMain)
                Spacer()
                StatusPill(text: session.busy ? "Busy" : "Idle",
                           tint: session.busy ? Theme.success : Theme.textSecondary)
            }
            Text(firstLine)
                .font(.subheadline)
                .foregroundStyle(Theme.textMain)
                .lineLimit(2)
            if let age {
                Text(age)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(minHeight: Theme.minTap)
        .card()
        .accessibilityElement(children: .combine)
    }
}
