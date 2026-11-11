import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // Menu-bar utility: no Dock icon (INFOPLIST_KEY_LSUIElement = YES), no main window.
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            // Focused workspace number, like AeroSpace's menu bar item.
            if model.wmStatus.isRunning, !model.wmStatus.focusedWorkspace.isEmpty {
                Text(model.wmStatus.focusedWorkspace)
            } else {
                Image(systemName: "rectangle.split.3x1")
            }
        }
        .menuBarExtraStyle(.window)

        Window("MacOSUtils Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 760, height: 560)
        .defaultLaunchBehavior(.suppressed)   // only open when asked
    }
}
