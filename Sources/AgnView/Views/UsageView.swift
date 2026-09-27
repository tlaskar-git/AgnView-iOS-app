import SwiftUI

struct UsageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScreenChrome(screen: .usage, actions: { actionRow }) {
            List {
                BannerSection()
                Section {
                    Text(model.canRefreshUsageOnHub ? "Refresh asks the hub to read every provider again"
                                                    : "Refresh reads the figures the hub already holds")
                        .captionRow()
                }
                if let notice = model.usageNotice {
                    Section {
                        Banner(kind: .info, text: notice, identifier: "usage-notice", card: false)
                    }
                }
                if let message = model.usageState.failureMessage {
                    Section {
                        PanelErrorCard(message: message, prefix: "usage", inList: true) {
                            Task { await model.retryUsage() }
                        }
                    }
                }
                if let snapshot = model.usageSnapshot, !snapshot.accounts.isEmpty {
                    ForEach(snapshot.accounts) { account in
                        UsageCard(account: account, takenAt: snapshot.takenAt,
                                  stale: !model.usageIsLive || model.usageState.failureMessage != nil)
                    }
                } else if model.usageState.failureMessage == nil {
                    Section {
                        Text(model.usageIsLive ? "Reading usage from the hub." : "No usage reading yet.")
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minHeight: Theme.minTap, alignment: .leading)
                            .accessibilityIdentifier("usage-empty")
                    }
                }
            }
            .refreshable { await model.refreshUsageFromHub() }
        }
        .task(id: model.usageIsLive) {
            while !Task.isCancelled {
                await model.refreshUsage()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private var actionRow: some View {
        ActionRow {
            UpdatedText(date: model.usageSnapshot?.takenAt, busy: model.usageRefreshing,
                        identifier: "usage-updated")
        } trailing: {
            ActionTextButton(title: "Refresh", busy: model.usageRefreshing,
                             disabled: model.usageRefreshing,
                             identifier: "usage-refresh") {
                Task { await model.refreshUsageFromHub() }
            }
        }
    }
}

/// The provider colours: violet, green, amber and cyan, as in the design.
private func providerTint(_ provider: String) -> Color {
    switch provider {
    case "antigravity": return Color(light: 0x6D28D9, dark: 0xC4B5FD)
    case "chatgpt": return Color(light: 0x047857, dark: 0x6EE7B7)
    case "claude": return Color(light: 0xB45309, dark: 0xFCD34D)
    case "gemini": return Color(light: 0x0E7490, dark: 0x67E8F9)
    default: return Theme.textSecondary
    }
}

/// One account as a section of rows: who it is, its limit windows, its
/// figures and when the hub last read it.
struct UsageCard: View {
    let account: UsageAccount
    let takenAt: Date
    let stale: Bool

    private var hubStale: Bool { account.usage?.isStale ?? false }

    var body: some View {
        Section {
            header
            if let plan = account.displayPlan {
                Text("Plan limits: " + plan)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("usage-plan")
            }
            if let message = account.displayError {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("usage-account-error")
            }
            if let usage = account.usage {
                ForEach(usage.windows) { window in
                    UsageWindowView(window: window, child: false)
                    ForEach(window.breakdown) { child in
                        UsageWindowView(window: child, child: true)
                            .padding(.leading, 16)
                    }
                }
            } else {
                legacyMetrics
            }
            figures
            footer
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(Format.providerName(account.provider).uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(providerTint(account.provider))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(providerTint(account.provider).opacity(0.15)))
                .accessibilityLabel(Format.providerName(account.provider))
                .accessibilityIdentifier("provider-" + account.provider)
            Text(account.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if stale {
                StatusPill(text: "Out of date", tint: Theme.warning)
                    .accessibilityIdentifier("usage-stale")
            }
            if let status = account.status, !status.isEmpty {
                StatusPill(text: status.capitalized, tint: statusTint(status))
                    .accessibilityIdentifier("usage-status")
            }
        }
        .frame(minHeight: Theme.minTap)
    }

    private struct FigureCell {
        let title: String
        let value: String
    }

    /// Tokens, cost and requests, only where the hub gave a figure.
    private var figureCells: [FigureCell] {
        var cells: [FigureCell] = []
        if account.usage != nil {
            if account.hasTokens { cells.append(FigureCell(title: "Tokens", value: tokenText)) }
            if account.hasCost { cells.append(FigureCell(title: "Cost", value: costText)) }
            if account.hasRequests {
                cells.append(FigureCell(title: "Requests", value: String(account.requestsCount)))
            }
        } else if account.hasRequests {
            cells.append(FigureCell(title: "Requests", value: String(account.requestsCount)))
        }
        return cells
    }

    @ViewBuilder
    private var figures: some View {
        let cells = figureCells
        if !cells.isEmpty {
            HStack(spacing: 8) {
                ForEach(cells, id: \.title) { cell in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cell.title)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(cell.value)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var footer: some View {
        let ageSeconds = Format.readingAge(hubAgeSeconds: account.usage?.ageSeconds, takenAt: takenAt, now: Date())
        return HStack(alignment: .firstTextBaseline) {
            if let source = account.usage?.sourceLabel, !source.isEmpty {
                Text(source)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("usage-source")
            }
            Spacer(minLength: 4)
            Text(Format.lastReading(seconds: ageSeconds) + (hubStale ? " (stale)" : ""))
                .font(.footnote)
                .foregroundStyle(hubStale ? Theme.warning : Theme.textSecondary)
                .accessibilityIdentifier("usage-age")
        }
    }

    /// Cards from a hub that sends only the flat fields. Null figures read
    /// "Not measured yet", as the hub gave nothing for them.
    @ViewBuilder
    private var legacyMetrics: some View {
        LegacyMetric(title: "Tokens",
                     value: account.hasTokens ? tokenText : PanelMessages.notMeasured,
                     fraction: account.hasTokens
                         ? Format.fraction(used: Double(account.tokensUsed),
                                           limit: account.tokensLimit.map { Double($0) })
                         : nil)
        LegacyMetric(title: "Cost",
                     value: account.hasCost ? costText : PanelMessages.notMeasured,
                     fraction: account.hasCost
                         ? Format.fraction(used: account.costUsed, limit: account.costLimit)
                         : nil)
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "active": return Theme.success
        case "warning": return Theme.warning
        case "exhausted", "error": return Theme.error
        default: return Theme.textSecondary
        }
    }

    private var tokenText: String {
        if let limit = account.tokensLimit {
            return Format.tokens(account.tokensUsed) + " / " + Format.tokens(limit)
        }
        return Format.tokens(account.tokensUsed)
    }

    private var costText: String {
        if let limit = account.costLimit {
            return Format.cost(account.costUsed) + " / " + Format.cost(limit)
        }
        return Format.cost(account.costUsed)
    }
}

/// One limit window: label, amount, countdown, share left and a bar.
struct UsageWindowView: View {
    let window: UsageWindowRow
    let child: Bool

    /// Colour by the hub's severity when it grades, otherwise by share.
    private var tint: Color {
        switch window.severity {
        case "exhausted", "critical": return Theme.error
        case "warning": return Theme.warning
        default: break
        }
        guard let percent = window.percentUsed else { return Theme.textSecondary }
        if percent >= 85 { return Theme.error }
        if percent >= 65 { return Theme.warning }
        return Theme.success
    }

    private var detailText: String {
        if !window.isMeasured { return window.subLabel ?? "" }
        return [window.countdownText, window.subLabel].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(child ? .caption.weight(.medium) : .subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let amount = window.amountText {
                    if window.isActive {
                        Text("Binding")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 4).stroke(Theme.textSecondary))
                    }
                    Text(amount)
                        .font((child ? Font.caption : Font.subheadline).weight(.bold))
                        .foregroundStyle(tint)
                } else {
                    Text(PanelMessages.notMeasured)
                        .font(.caption.italic())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !detailText.isEmpty || window.percentLeft != nil {
                HStack {
                    Text(detailText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let left = window.percentLeft {
                        Text(Format.percent(left) + " left")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            if let fraction = window.barFraction {
                ProgressView(value: max(fraction, 0.01))
                    .tint(tint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(child ? "usage-breakdown" : "usage-window")
    }
}

private struct LegacyMetric: View {
    let title: String
    let value: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if let fraction {
                ProgressView(value: fraction)
                    .tint(Theme.action)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
