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
            .animation(.easeOut(duration: 0.25), value: nav.toast)
            .sheet(isPresented: $nav.showPairing) {
                PairingSheet()
                    .environmentObject(model)
                    .environmentObject(nav)
            }
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
            phoneLayout
        }
    }

    /// The native TabView keeps each tab's own stack and scroll position. Its
    /// bar is hidden and the floating bar draws over it. Each screen adds a
    /// bottom inset the size of the bar, so nothing hides behind it.
    private var phoneLayout: some View {
        let safeBottom = SafeArea.bottom
        let inset = TabBarMetrics.contentInset(safeBottom: safeBottom)
        return TabView(selection: $nav.screen) {
            ForEach(Screen.phoneOrder) { screen in
                NavigationStack {
                    ScreenRouter(screen: screen)
                }
                .toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: nav.keyboardVisible ? 0 : inset)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
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
                .animation(.easeInOut(duration: 0.25), value: nav.keyboardVisible)
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
