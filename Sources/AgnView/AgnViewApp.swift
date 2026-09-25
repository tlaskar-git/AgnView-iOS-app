import SwiftUI

@main
struct AgnViewApp: App {
    @StateObject private var model = AppModel.forLaunch()
    @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(AppearanceChoice.scheme(for: appearance))
                .task { model.start() }
                .onOpenURL { url in model.pair(url: url) }
        }
    }
}
