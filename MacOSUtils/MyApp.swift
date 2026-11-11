import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // Menu-bar utility: no Dock icon (INFOPLIST_KEY_LSUIElement = YES), no main window.
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("MacOSUtils Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 760, height: 560)
        .defaultLaunchBehavior(.suppressed)   // only open when asked
    }
}

/// Status item label: the focused workspace number, like AeroSpace's menu bar item. It exists
/// for the app's whole lifetime, so it's also where the bar gets its "open Settings" action.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.wmStatus.isRunning, !model.wmStatus.focusedWorkspace.isEmpty {
                Text(model.wmStatus.focusedWorkspace)
            } else {
                Image(systemName: "rectangle.split.3x1")
            }
        }
        .onAppear {
            model.openSettingsWindow = { [openWindow] in
                openWindow(id: "settings")
                NSApp.activate()
            }
        }
    }
}
