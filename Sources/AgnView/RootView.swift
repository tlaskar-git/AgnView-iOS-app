import SwiftUI

struct RootView: View {
    @State private var selection: Screen? = .console
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            NavigationSplitView(columnVisibility: $columns) {
                List(Screen.allCases, selection: $selection) { screen in
                    Label(screen.title, systemImage: screen.symbol)
                        .tag(screen)
                        .accessibilityIdentifier("nav-" + screen.rawValue)
                }
                .navigationTitle("AgnView")
            } detail: {
                ScreenView(screen: selection ?? .console)
            }
        } else {
            TabView {
                ForEach(Screen.allCases) { screen in
                    ScreenView(screen: screen)
                        .tabItem { Label(screen.title, systemImage: screen.symbol) }
                }
            }
        }
    }
}

struct ScreenView: View {
    let screen: Screen
    @EnvironmentObject private var state: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(screen.title)
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier(screen.identifier)
                    Spacer()
                    RoutePill(route: state.route)
                }
                content
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: screen) {
            if screen == .usage {
                await state.refreshUsage()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .console:
            Text(state.statusLine)
                .accessibilityIdentifier("status-line")
            Text("Live agent output appears here.")
                .foregroundStyle(.secondary)
        case .sessions:
            Text("Agent sessions appear here.")
                .foregroundStyle(.secondary)
        case .pipelines:
            Text("Pipelines and tasks appear here.")
                .foregroundStyle(.secondary)
        case .usage:
            if state.usage.isEmpty {
                Text("Subscription usage appears here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.usage) { account in
                    Text(account.provider.capitalized)
                        .font(.headline)
                        .accessibilityIdentifier("provider-" + account.provider)
                }
            }
        case .settings:
            Text("Pairing and app settings appear here.")
                .foregroundStyle(.secondary)
        }
    }
}

struct RoutePill: View {
    let route: Route

    var body: some View {
        Text(route.label)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(route == .offline ? Color.gray.opacity(0.3) : Color.green.opacity(0.3)))
            .accessibilityIdentifier("route-pill")
    }
}
