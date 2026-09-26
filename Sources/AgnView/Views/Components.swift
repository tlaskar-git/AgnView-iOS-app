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
    /// A card outside lists. In a list the row carries the tint instead.
    var card = true

    private var tint: Color {
        switch kind {
        case .info: return Theme.link
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

    private var line: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    var body: some View {
        if card {
            line
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(tint.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(tint.opacity(0.4), lineWidth: 1))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
        } else {
            line
                .listRowBackground(ZStack {
                    Theme.surface
                    tint.opacity(0.12)
                })
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
        }
    }
}

struct RoutePill: View {
    @EnvironmentObject private var model: AppModel

    private var label: String {
        if case .connecting = model.connection, model.activeHub != nil { return "Connecting" }
        return model.routeLabel
    }

    private var tint: Color {
        if model.isDemo { return Theme.warning }
        switch model.route {
        case .lan: return Theme.success
        case .direct, .relay: return Theme.link
        case .offline: return Theme.textSecondary
        }
    }

    /// A coloured dot and the route name. It lives in the navigation bar, so
    /// the system draws the bar item background and the text stays primary.
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
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
    /// Extra views under the buttons, such as a link.
    var accessory: AnyView?

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
            if let accessory { accessory }
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
/// identifiers are prefix-error, prefix-error-text and prefix-retry. In a list
/// the message and Retry are two rows.
struct PanelErrorCard: View {
    let message: String
    let prefix: String
    var inList = false
    let retry: () -> Void

    @ViewBuilder
    var body: some View {
        if inList {
            Banner(kind: .error, text: message, identifier: prefix + "-error", card: false)
            Button("Retry", action: retry)
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier(prefix + "-retry")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Banner(kind: .error, text: message, identifier: prefix + "-error")
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
                    .frame(minHeight: Theme.minTap)
                    .accessibilityIdentifier(prefix + "-retry")
            }
        }
    }
}

extension View {
    /// Styles a line of explanatory text in a list: small, secondary, with no
    /// row background.
    func captionRow() -> some View {
        self.font(.footnote)
            .foregroundStyle(Theme.textSecondary)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }
}

enum Keyboard {
    /// Closes the keyboard from anywhere.
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

enum ScreenGate {
    case none, noHub, offline, authFailed, keyRevoked
}

/// The banners that sit above a screen's content: the relay-only and not-on-
/// the-same-network warnings and the dismissable notice. In a list each one is
/// a row, elsewhere each one is a card.
struct ScreenBanners: View {
    let inList: Bool

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: NavState

    var body: some View {
        if let reason = model.lanUnavailableReason {
            switch reason {
            case .pairedWithoutLAN:
                Banner(kind: .warning, text: UserMessages.pairedWithoutLANBanner,
                       identifier: "banner-relay-only", card: !inList)
                Button("Scan the QR code again") { nav.showPairing = true }
                    .frame(minHeight: Theme.minTap)
                    .accessibilityIdentifier("banner-scan-again")
            case .notOnSameNetwork:
                Banner(kind: .warning, text: UserMessages.notOnSameNetworkBanner,
                       identifier: "banner-not-on-network", card: !inList)
            }
        }
        if let notice = model.notice {
            Banner(kind: .info, text: notice, identifier: "banner-notice", card: !inList)
            Button("Dismiss") { model.notice = nil }
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("banner-notice-dismiss")
        }
    }
}

/// The banner rows for a List or Form. Draws nothing when there is no banner.
struct BannerSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.lanUnavailableReason != nil || model.notice != nil {
            Section {
                ScreenBanners(inList: true)
            }
        }
    }
}

/// The frame every screen shares: the system large title, the route pill in
/// the top trailing toolbar, and either a full-screen state or the content.
/// Each screen sits in its own NavigationStack (see RootView).
struct ScreenChrome<Content: View, Trailing: View>: View {
    let screen: Screen
    private let trailing: Trailing
    private let content: Content

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: NavState

    /// The content is a List, a Form or its own layout. It scrolls, refreshes
    /// and shows its banners itself.
    init(screen: Screen,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.screen = screen
        self.trailing = trailing()
        self.content = content()
    }

    private var gate: ScreenGate {
        if screen == .settings { return .none }
        if model.hubs.isEmpty && !model.isDemo { return .noHub }
        switch model.connection {
        case .offline: return .offline
        case .authFailed: return .authFailed
        case .keyRevoked: return .keyRevoked
        default: return .none
        }
    }

    var body: some View {
        chromeBody
            .navigationTitle(screen.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    trailing
                    RoutePill()
                }
            }
            // A container with its own identifier. A bare identifier on a plain
            // stack would replace the identifiers of everything inside it.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(screen.identifier)
    }

    @ViewBuilder
    private var chromeBody: some View {
        if gate != .none {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacing) {
                    ScreenBanners(inList: false)
                    gateView
                }
                .padding(.horizontal, Theme.screenPadding)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.page.ignoresSafeArea())
        } else {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.isDemo { DemoBanner() }
                }
        }
    }

    @ViewBuilder
    private var gateView: some View {
        switch gate {
        case .noHub:
            StateView(symbol: "qrcode.viewfinder",
                      title: "Pair your computer",
                      message: "AgnView for iOS is a companion. Install the free AgnView app on your Windows PC or Mac, then scan its pairing QR code here.",
                      identifier: "state-onboarding",
                      primaryTitle: "Scan QR code",
                      primary: { nav.showPairing = true },
                      secondaryTitle: "Paste pairing link",
                      secondary: { nav.showPairing = true },
                      settingsTitle: "Settings",
                      settings: { nav.screen = .settings },
                      accessory: AnyView(OnboardingLinks()))
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

extension ScreenChrome where Trailing == EmptyView {
    init(screen: Screen, @ViewBuilder content: () -> Content) {
        self.init(screen: screen, trailing: { EmptyView() }, content: content)
    }
}
