import SwiftUI

struct UsageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScreenChrome(screen: .usage) {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if let notice = model.usageNotice {
                    Banner(kind: .info, text: notice, identifier: "usage-notice")
                }
                if let snapshot = model.usageSnapshot, !snapshot.accounts.isEmpty {
                    ForEach(snapshot.accounts) { account in
                        UsageCard(account: account, takenAt: snapshot.takenAt, stale: !model.usageIsLive)
                    }
                } else {
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
            Metric(title: "Tokens",
                   value: tokenText,
                   fraction: Format.fraction(used: Double(account.tokensUsed),
                                             limit: account.tokensLimit.map { Double($0) }))
            Metric(title: "Cost",
                   value: costText,
                   fraction: Format.fraction(used: account.costUsed, limit: account.costLimit))
            Metric(title: "Requests", value: String(account.requestsCount), fraction: nil)
            Text(Format.lastReading(from: takenAt, to: Date()))
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("usage-age")
        }
        .card()
        .opacity(stale ? 0.55 : 1)
        .accessibilityElement(children: .contain)
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
