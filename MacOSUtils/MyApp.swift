import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // Menu-bar utility: no Dock icon (INFOPLIST_KEY_LSUIElement = YES), no main window.
        MenuBarExtra("MacOSUtils", systemImage: "arrow.up.arrow.down") {
            ContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
