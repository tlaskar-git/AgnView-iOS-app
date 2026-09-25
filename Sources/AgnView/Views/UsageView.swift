import SwiftUI

struct UsageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScreenChrome(screen: .usage) {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let notice = model.usageNotice {
                    Banner(kind: .info, text: notice, identifier: "usage-notice")
                }
                if let message = model.usageState.failureMessage {
                    PanelErrorCard(message: message, prefix: "usage") {
                        Task { await model.retryUsage() }
                    }
                }
                if let snapshot = model.usageSnapshot, !snapshot.accounts.isEmpty {
                    ForEach(snapshot.accounts) { account in
                        UsageCard(account: account, takenAt: snapshot.takenAt,
                                  stale: !model.usageIsLive || model.usageState.failureMessage != nil)
                    }
                } else if model.usageState.failureMessage == nil {
                    Text(model.usageIsLive ? "Reading usage from the hub." : "No usage reading yet.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                        .accessibilityIdentifier("usage-empty")
                }
            }
            .padding(.bottom, 16)
        }
        .task(id: model.usageIsLive) {
            while !Task.isCancelled {
                await model.refreshUsage()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
}

struct UsageCard: View {
    let account: UsageAccount
    let takenAt: Date
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.providerName(account.provider))
                    .font(.headline)
                    .foregroundStyle(Theme.textMain)
                    .accessibilityIdentifier("provider-" + account.provider)
                Spacer()
                if let plan = account.planName, !plan.isEmpty {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if account.status != nil || account.errorMessage != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let status = account.status, !status.isEmpty {
                        StatusPill(text: status.capitalized, tint: statusTint(status))
                            .accessibilityIdentifier("usage-status")
                    }
                    if let message = account.errorMessage, !message.isEmpty {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("usage-account-error")
                    }
                }
            }
            Metric(title: "Tokens",
                   value: account.hasTokens ? tokenText : PanelMessages.notMeasured,
                   fraction: account.hasTokens
                       ? Format.fraction(used: Double(account.tokensUsed),
                                         limit: account.tokensLimit.map { Double($0) })
                       : nil)
            Metric(title: "Cost",
                   value: account.hasCost ? costText : PanelMessages.notMeasured,
                   fraction: account.hasCost
                       ? Format.fraction(used: account.costUsed, limit: account.costLimit)
                       : nil)
            Metric(title: "Requests",
                   value: account.hasRequests ? String(account.requestsCount) : PanelMessages.notMeasured,
                   fraction: nil)
            Text(Format.lastReading(from: takenAt, to: Date()))
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("usage-age")
        }
        .card()
        .opacity(stale ? 0.55 : 1)
        .accessibilityElement(children: .contain)
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

private struct Metric: View {
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
                    .foregroundStyle(Theme.textMain)
            }
            if let fraction {
                ProgressView(value: fraction)
                    .tint(Theme.action)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
