import SwiftUI

@main
struct SoundDialApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(model)
        } label: {
            Image(systemName: "dial.medium.fill")
        }
        .menuBarExtraStyle(.window)

        Window("SoundDial", id: "routing") {
            RoutingView().environment(model)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
