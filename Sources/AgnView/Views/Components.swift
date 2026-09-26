import SwiftUI

/// Shared state that crosses screens: the selected screen and the pairing sheet.
@MainActor
final class NavState: ObservableObject {
    @Published var screen: Screen = .console
    @Published var showPairing = false
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.border, lineWidth: 1))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct Banner: View {
    enum Kind { case info, warning, error }

    let kind: Kind
    let text: String
    let identifier: String

    private var tint: Color {
        switch kind {
        case .info: return Theme.action
        case .warning: return Theme.warning
        case .error: return Theme.error
        }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textMain)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(tint.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

struct RoutePill: View {
    @EnvironmentObject private var model: AppModel

    private var label: String {
        if case .connecting = model.connection, model.activeHub != nil { return "Connecting" }
        return model.route.label
    }

    private var tint: Color {
        switch model.route {
        case .lan: return Theme.success
        case .direct, .relay: return Theme.action
        case .offline: return Theme.textSecondary
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.15)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connection: \(label)")
            .accessibilityIdentifier("route-pill")
    }
}

/// A status pill with a fixed tint.
struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

/// A full-screen state with a message and one or two actions.
struct StateView: View {
    let symbol: String
    let title: String
    let message: String
    let identifier: String
    let primaryTitle: String
    let primary: () -> Void
    var secondaryTitle: String?
    var secondary: (() -> Void)?
    /// Always offered, so no state can trap the user away from Settings.
    var settingsTitle = "Switch machine"
    var settings: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(Theme.textMain)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(primaryTitle, action: primary)
                .buttonStyle(.borderedProminent)
                .tint(Theme.action)
                .controlSize(.large)
                .accessibilityIdentifier(identifier + "-primary")
            if let secondaryTitle, let secondary {
                Button(secondaryTitle, action: secondary)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier(identifier + "-secondary")
            }
            if let settings {
                Button(settingsTitle, action: settings)
                    .frame(minHeight: Theme.minTap)
                    .accessibilityIdentifier(identifier + "-settings")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// The message a panel shows when its own request failed, with Retry. The
/// identifiers are prefix-error, prefix-error-text and prefix-retry.
struct PanelErrorCard: View {
    let message: String
    let prefix: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Banner(kind: .error, text: message, identifier: prefix + "-error")
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier(prefix + "-retry")
        }
    }
}

enum Keyboard {
    /// Closes the keyboard from anywhere.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

/// Adds pull to refresh when there is an action for it.
struct OptionalRefresh: ViewModifier {
    let action: (() async -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.refreshable { await action() }
        } else {
            content
        }
    }
}

/// A small pill button with an icon, for actions such as Refresh.
struct PillButton: View {
    let title: String
    let symbol: String
    let identifier: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.action)
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.minTap)
            .background(Capsule().fill(Theme.raised))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityIdentifier(identifier)
    }
}

enum ScreenGate {
    case none, noHub, offline, authFailed, keyRevoked
}

/// The frame every screen shares: title, route pill, banners, then either a
/// full-screen state or the screen content.
struct ScreenChrome<Content: View>: View {
    let screen: Screen
    let scrolls: Bool
    /// When set, the screen scrolls and supports pull to refresh.
    let onRefresh: (() async -> Void)?
    private let content: Content

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: NavState

    init(screen: Screen, scrolls: Bool = true, onRefresh: (() async -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.screen = screen
        self.scrolls = scrolls
        self.onRefresh = onRefresh
        self.content = content()
    }

    private var gate: ScreenGate {
        if screen == .settings { return .none }
        if model.hubs.isEmpty { return .noHub }
        switch model.connection {
        case .offline: return .offline
        case .authFailed: return .authFailed
        case .keyRevoked: return .keyRevoked
        default: return .none
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing) {
            banners
            if gate != .none {
                ScrollView { gateView }
                    .scrollDismissesKeyboard(.interactively)
            } else if scrolls {
                ScrollView {
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                .modifier(OptionalRefresh(action: onRefresh))
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.page.ignoresSafeArea())
        // The screen sits in its own NavigationStack (see RootView), so the
        // title is the system large title and the route pill is a toolbar item.
        .navigationTitle(screen.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                RoutePill()
            }
        }
        .accessibilityIdentifier(screen.identifier)
    }

    @ViewBuilder
    private var banners: some View {
        if let reason = model.lanUnavailableReason {
            switch reason {
            case .pairedWithoutLAN:
                VStack(alignment: .leading, spacing: 8) {
                    Banner(kind: .warning, text: UserMessages.pairedWithoutLANBanner,
                           identifier: "banner-relay-only")
                    Button("Scan the QR code again") { nav.showPairing = true }
                        .frame(minHeight: Theme.minTap)
                        .accessibilityIdentifier("banner-scan-again")
                }
            case .notOnSameNetwork:
                Banner(kind: .warning, text: UserMessages.notOnSameNetworkBanner,
                       identifier: "banner-not-on-network")
            }
        }
        if let notice = model.notice {
            HStack(alignment: .top) {
                Banner(kind: .info, text: notice, identifier: "banner-notice")
                Button("Dismiss") { model.notice = nil }
                    .frame(minHeight: Theme.minTap)
                    .accessibilityIdentifier("banner-notice-dismiss")
            }
        }
    }

    @ViewBuilder
    private var gateView: some View {
        switch gate {
        case .noHub:
            StateView(symbol: "qrcode.viewfinder",
                      title: "Pair your computer",
                      message: "Open AgnView on your computer, show the pairing QR code, then scan it here.",
                      identifier: "state-onboarding",
                      primaryTitle: "Scan QR code",
                      primary: { nav.showPairing = true },
                      secondaryTitle: "Paste pairing link",
                      secondary: { nav.showPairing = true },
                      settingsTitle: "Settings",
                      settings: { nav.screen = .settings })
        case .offline:
            StateView(symbol: "wifi.slash",
                      title: "Hub offline",
                      message: UserMessages.offlineHub,
                      identifier: "state-offline",
                      primaryTitle: "Retry",
                      primary: { model.retry() },
                      settings: { nav.screen = .settings })
        case .authFailed:
            StateView(symbol: "lock.slash",
                      title: "Pairing rejected",
                      message: UserMessages.authFailed,
                      identifier: "state-authFailed",
                      primaryTitle: "Scan again",
                      primary: { nav.showPairing = true },
                      settings: { nav.screen = .settings })
        case .keyRevoked:
            StateView(symbol: "key",
                      title: "Key changed",
                      message: UserMessages.keyRevoked,
                      identifier: "state-keyRevoked",
                      primaryTitle: "Pair again",
                      primary: { nav.showPairing = true },
                      settings: { nav.screen = .settings })
        case .none:
            EmptyView()
        }
    }
}
