import SwiftUI

/// Menu-bar panel: window manager status and scroll settings.
struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.isAccessibilityTrusted {
                permissionBanner
            }

            windowManagerSection

            Divider()

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
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate()   // menu-bar apps aren't active by default
                }
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

    private var windowManagerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Tiling window manager", isOn: $model.isWindowManagerEnabled)
                .toggleStyle(.switch)

            Toggle("Focused window border", isOn: $model.isFocusBorderEnabled)
                .help("Draws the outline itself, using active_color and width from the `borders` line in your config. Off = launch JankyBorders instead.")
                .disabled(!model.isWindowManagerEnabled)

            if model.wmStatus.isRunning {
                HStack(spacing: 4) {
                    ForEach(model.wmStatus.allWorkspaces, id: \.self) { name in
                        workspaceButton(name)
                    }
                }
                HStack {
                    Text("\(model.wmStatus.windowCount) windows")
                    if model.wmStatus.mode != "main" {
                        Text("· mode: \(model.wmStatus.mode)").foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Reload Config") { model.reloadWindowManagerConfig() }
                        .controlSize(.small)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Config: \(model.wmStatus.configSource)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ForEach(model.wmStatus.configErrors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func workspaceButton(_ name: String) -> some View {
        let isFocused = model.wmStatus.focusedWorkspace == name
        let isOccupied = model.wmStatus.occupiedWorkspaces.contains(name)
        let isVisible = model.wmStatus.visibleWorkspaces.contains(name)
        return Button {
            model.switchWorkspace(name)
        } label: {
            Text(name)
                .font(.system(.caption, design: .monospaced).weight(isFocused ? .bold : .regular))
                .frame(minWidth: 22, minHeight: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isFocused ? Color.accentColor.opacity(0.85)
                              : isVisible ? Color.accentColor.opacity(0.3)
                              : isOccupied ? Color.secondary.opacity(0.25) : Color.clear)
                )
                .foregroundStyle(isFocused ? Color.white : isOccupied || isVisible ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility access needed")
                .fontWeight(.semibold)
            Text("Scroll reversal and window management both need Accessibility permission to read input and move windows.")
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
