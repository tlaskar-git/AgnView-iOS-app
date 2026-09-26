import SwiftUI

/// Shared state that crosses screens: the selected screen and the pairing sheet.
@MainActor
final class NavState: ObservableObject {
    @Published var screen: Screen = .console
    @Published var showPairing = false
    /// True while the software keyboard is up. The tab bar hides and the
    /// screens stop reserving room for it.
    @Published var keyboardVisible = false
    /// A short confirmation that fades by itself, such as "Switched to Studio".
    @Published private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

/// The toast: a dark capsule under the header.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(light: 0x1C1C20, dark: 0x3A3A3F)))
            .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 24)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .accessibilityIdentifier("toast")
    }
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

/// The frame every screen shares: the custom header row (large title and the
/// route pill), an optional action row, and either a full-screen state or the
/// content. Each screen sits in its own NavigationStack (see RootView). The
/// system navigation bar stays hidden on the screen roots, so nothing the
/// system draws can clip the pill.
struct ScreenChrome<Content: View, Actions: View>: View {
    let screen: Screen
    private let actions: Actions
    private let content: Content

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: NavState

    /// The content is a List, a Form or its own layout. It scrolls, refreshes
    /// and shows its banners itself.
    init(screen: Screen,
         @ViewBuilder actions: () -> Actions,
         @ViewBuilder content: () -> Content) {
        self.screen = screen
        self.actions = actions()
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

    /// The canvas behind the header and the content.
    private var canvas: Color {
        screen == .console ? Theme.chatBackground : Theme.page
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: screen.title)
            actions
            chromeBody
        }
        .background(canvas.ignoresSafeArea())
        .navigationTitle(screen.title)
        .navigationBarTitleDisplayMode(.inline)
        // The phone hides the bar. On iPad the bar stays for the sidebar button
        // and shows no title of its own.
        .toolbar(HeaderMetrics.isPad ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if HeaderMetrics.isPad {
                ToolbarItem(placement: .principal) {
                    Text("").accessibilityHidden(true)
                }
            }
        }
        .scrollsToTopOnTabTap(screen)
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
            .background(canvas.ignoresSafeArea())
        } else {
            content
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

extension ScreenChrome where Actions == EmptyView {
    init(screen: Screen, @ViewBuilder content: () -> Content) {
        self.init(screen: screen, actions: { EmptyView() }, content: content)
    }
}
