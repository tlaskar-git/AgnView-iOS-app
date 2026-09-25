import SwiftUI

@main
struct AgnViewApp: App {
    @StateObject private var model = AppModel.forLaunch()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .task { model.start() }
                .onOpenURL { url in model.pair(url: url) }
        }
    }
}
