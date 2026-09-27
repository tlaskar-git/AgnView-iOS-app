import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var nav = NavState()
    @State private var columns: NavigationSplitViewVisibility = .all

    private var sidebarSelection: Binding<Screen?> {
        Binding(get: { nav.screen },
                set: { if let value = $0 { nav.screen = value } })
    }

    var body: some View {
        layout
            .environmentObject(nav)
            .tint(Theme.link)
            .modifier(NavChrome(nav: nav))
    }

    @ViewBuilder
    private var layout: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView(columnVisibility: $columns) {
                List(Screen.allCases, selection: sidebarSelection) { screen in
                    Label(screen.title, systemImage: screen.symbol)
                        .tag(screen)
                        .frame(minHeight: Theme.minTap)
                        .accessibilityIdentifier("nav-" + screen.rawValue)
                }
                .navigationTitle("AgnView")
            } detail: {
                // The detail column is its own stack, so every screen gets a
                // large title and a toolbar like a tab does on iPhone.
                NavigationStack {
                    ScreenRouter(screen: nav.screen)
                }
            }
        } else {
            PhoneShell(nav: nav)
        }
    }
}

/// The keyboard watcher, the toast and the pairing sheet. A modifier of its own
/// that observes the navigation state directly, so a change shows at once.
private struct NavChrome: ViewModifier {
    @ObservedObject var nav: NavState
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                nav.keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                nav.keyboardVisible = false
            }
            .overlay(alignment: .top) {
                if let text = nav.toast {
                    ToastView(text: text)
                        .padding(.top, HeaderMetrics.rowHeight + 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(isPresented: $nav.showPairing) {
                PairingSheet()
                    .environmentObject(model)
                    .environmentObject(nav)
            }
    }
}

/// The iPhone shell. The native TabView keeps each tab's own stack and scroll
/// position. Its bar is hidden and the floating bar draws over it. Each screen
/// adds a bottom inset the size of the bar (see TabBarClearance), so nothing
/// hides behind it. It observes the navigation state itself.
private struct PhoneShell: View {
    @ObservedObject var nav: NavState

    /// Counts the changes of the navigation state. The shell reads it, so a
    /// change of the selected tab or of the keyboard always draws again.
    @State private var changes = 0
    @Environment(\.verticalSizeClass) private var verticalSize

    var body: some View {
        _ = changes
        let safeBottom = nav.safeBottom
        return TabView(selection: $nav.screen) {
            ForEach(Screen.phoneOrder) { screen in
                NavigationStack {
                    ScreenRouter(screen: screen)
                }
                .toolbar(.hidden, for: .tabBar)
                .tabItem { Label(screen.title, systemImage: screen.symbol) }
                .tag(screen)
            }
        }
        .overlay(alignment: .bottom) {
            FloatingTabBar(selection: $nav.screen) { ScrollToTop.post($0) }
                .padding(.bottom, TabBarMetrics.bottomGap(safeBottom: safeBottom) - safeBottom)
                .offset(y: nav.keyboardVisible ? 200 : 0)
                .opacity(nav.keyboardVisible ? 0 : 1)
                .allowsHitTesting(!nav.keyboardVisible)
                .accessibilityHidden(nav.keyboardVisible)
        }
        .onReceive(nav.objectWillChange) { _ in changes &+= 1 }
        .onAppear { nav.safeBottom = SafeArea.bottom }
        .onChange(of: verticalSize) { _, _ in
            DispatchQueue.main.async { nav.safeBottom = SafeArea.bottom }
        }
    }
}

struct ScreenRouter: View {
    let screen: Screen

    var body: some View {
        switch screen {
        case .console: ConsoleView()
        case .sessions: SessionsView()
        case .pipelines: PipelinesView()
        case .usage: UsageView()
        case .settings: SettingsView()
        }
    }
}
