import SwiftUI

/// The size and spacing rules of the approved header.
enum HeaderMetrics {
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// Left inset of the title and the action row.
    static var leadingInset: CGFloat { isPad ? 24 : 16 }
    /// Right inset of the route pill. It never moves past this.
    static var trailingInset: CGFloat { isPad ? 24 : 16 }
    static let rowHeight: CGFloat = 60
    static let pillHeight: CGFloat = 40
    static let pillMinWidth: CGFloat = 78
    static let pillHorizontalPadding: CGFloat = 16
    static let dotSize: CGFloat = 9
    static let actionRowHeight: CGFloat = 44
}

/// The connection type as a glass capsule: a coloured dot and the route name.
/// It keeps its full width for LAN, Direct, Relay, Offline and Connecting at
/// every text size, so the title gives way before the pill does.
struct RoutePill: View {
    @EnvironmentObject private var model: AppModel

    @ScaledMetric(relativeTo: .subheadline) private var height = HeaderMetrics.pillHeight
    @ScaledMetric(relativeTo: .subheadline) private var dot = HeaderMetrics.dotSize

    /// The words on the pill.
    static func label(route: Route, connecting: Bool) -> String {
        connecting ? "Connecting" : route.label
    }

    private var connecting: Bool {
        if case .connecting = model.connection, model.activeHub != nil { return true }
        return false
    }

    private var label: String { Self.label(route: model.route, connecting: connecting) }

    private var tint: Color {
        connecting ? Theme.textSecondary : Theme.routeColor(model.route)
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: dot, height: dot)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, HeaderMetrics.pillHorizontalPadding)
        .frame(minWidth: HeaderMetrics.pillMinWidth, minHeight: height)
        .glassSurface(Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection: \(label)")
        .accessibilityIdentifier("route-pill")
    }
}

/// The large title on the left and the route pill on the right, centred on
/// one line. The title truncates before the pill does.
struct ScreenHeader: View {
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen-title")
            Spacer(minLength: 8)
            RoutePill()
                .layoutPriority(1)
        }
        .padding(.leading, HeaderMetrics.leadingInset)
        .padding(.trailing, HeaderMetrics.trailingInset)
        .frame(maxWidth: .infinity, minHeight: HeaderMetrics.rowHeight, alignment: .center)
    }
}

/// The line under the title on Sessions, Pipelines and Usage: a status text at
/// the left and one text button at the right.
struct ActionRow<Status: View, Trailing: View>: View {
    private let status: Status
    private let trailing: Trailing

    init(@ViewBuilder status: () -> Status, @ViewBuilder trailing: () -> Trailing) {
        self.status = status()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            status
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, HeaderMetrics.leadingInset)
        .padding(.trailing, max(HeaderMetrics.trailingInset - 6, 8))
        .frame(maxWidth: .infinity, minHeight: HeaderMetrics.actionRowHeight)
    }
}

/// "Updated 50s ago", from the last refresh. The text refreshes every 30 s.
struct UpdatedText: View {
    let date: Date?
    var busy = false
    let identifier: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(busy ? "Refreshing..." : Format.updated(from: date, to: context.date))
                .accessibilityIdentifier(identifier)
        }
    }
}

/// The one text button of an action row: 17 pt semibold, at least 44 by 44.
struct ActionTextButton: View {
    let title: String
    var systemImage: String?
    var busy = false
    var disabled = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.headline)
            .foregroundStyle(Theme.link)
            .padding(.horizontal, 6)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}
