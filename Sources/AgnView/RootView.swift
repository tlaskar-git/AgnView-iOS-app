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
            TabView(selection: $nav.screen) {
                ForEach(Screen.allCases) { screen in
                    NavigationStack {
                        ScreenRouter(screen: screen)
                    }
                    .tabItem { Label(screen.title, systemImage: screen.symbol) }
                    .tag(screen)
                }
            }
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
