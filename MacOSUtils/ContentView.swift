import SwiftUI

/// Menu-bar panel. Scroll settings for now; window-manager controls go here later.
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.isAccessibilityTrusted {
                permissionBanner
            }

            Toggle("Manage scroll direction", isOn: $model.scrollSettings.enabled)
                .toggleStyle(.switch)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("Vertical").font(.caption).foregroundStyle(.secondary)
                    Text("Horizontal").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(ScrollSource.allCases) { source in
                    GridRow {
                        Label(source.displayName, systemImage: icon(for: source))
                            .fontWeight(model.lastScrollSource == source ? .semibold : .regular)
                        directionPicker($model.scrollSettings[source].vertical)
                        directionPicker($model.scrollSettings[source].horizontal)
                    }
                }
            }
            .disabled(!model.scrollSettings.enabled)

            Stepper(value: $model.scrollSettings[.wheelMouse].discreteStepSize, in: 0...20) {
                let step = model.scrollSettings[.wheelMouse].discreteStepSize
                Text(step == 0 ? "Wheel step: macOS default" : "Wheel step: \(step) line\(step == 1 ? "" : "s")")
            }
            .disabled(!model.scrollSettings.enabled)

            Toggle("Ignore scrolls posted by other apps", isOn: $model.scrollSettings.onlyHardwareEvents)
                .help("Leave alone scroll events synthesised by remote-desktop tools, BetterTouchTool, etc.")

            Divider()

            HStack {
                if let source = model.lastScrollSource {
                    Text("Last scroll: \(source.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") {
                    model.stopAll()
                    NSApp.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 400)
    }

    private var header: some View {
        HStack {
            Text("MacOSUtils").font(.headline)
            Spacer()
            Circle()
                .fill(model.isScrollTapRunning ? .green : .orange)
                .frame(width: 8, height: 8)
            Text(model.isScrollTapRunning ? "Active" : "Inactive")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility access needed")
                .fontWeight(.semibold)
            Text("Scroll reversal and window management both need permission to read and modify input events.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Grant Access…") { model.requestAccessibility() }
                Button("Open Settings") { model.openAccessibilitySettings() }
            }
            Text("Already switched on in Settings? That entry belongs to an earlier build. Reset it, then allow this build.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset Permission & Ask Again") { model.resetAccessibilityPermission() }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func directionPicker(_ binding: Binding<ScrollDirection>) -> some View {
        Picker("", selection: binding) {
            ForEach(ScrollDirection.allCases) { Text($0.displayName).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func icon(for source: ScrollSource) -> String {
        switch source {
        case .trackpad:   "rectangle.and.hand.point.up.left"
        case .magicMouse: "magicmouse"
        case .wheelMouse: "computermouse"
        }
    }
}
