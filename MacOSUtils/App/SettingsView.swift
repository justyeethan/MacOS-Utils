import AppKit
import SwiftUI

/// Settings window: keybindings and window borders. Edits are kept until Save or Revert;
/// border changes preview live on your windows.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let doc = model.configDocument
        VStack(spacing: 0) {
            TabView {
                KeybindingsSettingsView(doc: doc, model: model)
                    .tabItem { Label("Keybindings", systemImage: "keyboard") }
                BorderSettingsView(doc: doc, model: model)
                    .tabItem { Label("Border", systemImage: "square.dashed") }
                BarSettingsView(doc: doc, model: model)
                    .tabItem { Label("Bar", systemImage: "menubar.rectangle") }
            }
            .padding([.horizontal, .top])

            Divider()
            footer(doc)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            // Pick up edits made to the file by hand, unless there are unsaved changes here.
            if !doc.isDirty { doc.load() }
        }
    }

    private func footer(_ doc: ConfigDocument) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Using \(doc.sourceDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = doc.loadError ?? model.configSaveError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if doc.isDirty {
                    Text("Unsaved changes — saved to ~/.config/macosutils/macosutils.toml")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if doc.isUsingOwnFile {
                Button("Use ~/.aerospace.toml…") { model.confirmUseAeroSpaceConfig = true }
                    .confirmationDialog(
                        "Move ~/.config/macosutils/macosutils.toml to the Trash and go back to ~/.aerospace.toml?",
                        isPresented: $model.confirmUseAeroSpaceConfig
                    ) {
                        Button("Move to Trash", role: .destructive) { model.useAeroSpaceConfig() }
                    }
            }
            Button("Revert") { model.revertConfig() }
                .disabled(!doc.isDirty)
            Button("Save") { model.saveConfig() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!doc.isDirty || doc.hasProblems || doc.loadError != nil)
        }
        .padding()
    }
}

// MARK: - Keybindings

struct KeybindingsSettingsView: View {
    @Bindable var doc: ConfigDocument
    let model: AppModel

    @State private var mode = "main"
    @State private var filter = ""
    @State private var newModeName = ""
    @State private var isAddingMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(doc.modeNames, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Button {
                    isAddingMode = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a binding mode")
                .popover(isPresented: $isAddingMode) {
                    HStack {
                        TextField("Mode name", text: $newModeName)
                            .frame(width: 160)
                            .onSubmit(addMode)
                        Button("Add", action: addMode)
                    }
                    .padding()
                }

                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Text(mode == "main"
                 ? "Always active. Click a shortcut to record a new one; separate multiple commands with “;”."
                 : "Active after a `mode \(mode)` command. Unbound keys type normally; end bindings with “mode main” to leave.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(visibleRows) { row in
                    BindingRowView(row: binding(for: row.id),
                                   problem: doc.problem(for: row, in: mode),
                                   onDelete: { doc.removeBinding(row.id, from: mode) },
                                   onRecordingChange: { model.setHotkeysSuspended($0) })
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Button {
                    filter = ""
                    doc.addBinding(to: mode)
                } label: {
                    Label("Add Binding", systemImage: "plus")
                }
                Spacer()
                Text("\(doc.bindings[mode]?.count ?? 0) bindings in “\(mode)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: doc.modeNames) {
            if !doc.modeNames.contains(mode) { mode = "main" }
        }
    }

    private var visibleRows: [ConfigDocument.BindingRow] {
        let rows = doc.bindings[mode] ?? []
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return rows }
        return rows.filter { $0.chord.lowercased().contains(f) || $0.commands.lowercased().contains(f) }
    }

    private func binding(for id: UUID) -> Binding<ConfigDocument.BindingRow> {
        Binding(
            get: { doc.bindings[mode]?.first { $0.id == id } ?? .init(chord: "", commands: "") },
            set: { newValue in
                guard let i = doc.bindings[mode]?.firstIndex(where: { $0.id == id }) else { return }
                doc.bindings[mode]?[i] = newValue
            }
        )
    }

    private func addMode() {
        doc.addMode(newModeName)
        if doc.modeNames.contains(newModeName.trimmingCharacters(in: .whitespaces)) {
            mode = newModeName.trimmingCharacters(in: .whitespaces)
        }
        newModeName = ""
        isAddingMode = false
    }
}

private struct BindingRowView: View {
    @Binding var row: ConfigDocument.BindingRow
    let problem: String?
    let onDelete: () -> Void
    let onRecordingChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ShortcutRecorder(chord: $row.chord, onRecordingChange: onRecordingChange)
                    .frame(width: 190, alignment: .leading)

                TextField("command", text: $row.commands)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                CommandPresetMenu { row.commands = $0 }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove binding")
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Click, then press the shortcut. Global hotkeys are paused while recording so chords that
/// are already bound (e.g. alt-h) reach this window instead of triggering.
struct ShortcutRecorder: View {
    @Binding var chord: String
    let onRecordingChange: (Bool) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            HStack {
                Image(systemName: isRecording ? "record.circle" : "keyboard")
                    .foregroundStyle(isRecording ? Color.red : Color.secondary)
                Text(isRecording ? "Press a shortcut…" : (chord.isEmpty ? "Click to record" : chord))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(chord.isEmpty && !isRecording ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let modifiers = KeyChord.Modifiers(nsFlags: event.modifierFlags)
            // Local monitors run on the main thread.
            MainActor.assumeIsolated {
                if let text = KeyChord.text(keyCode: keyCode, modifiers: modifiers) {
                    chord = text
                }
                stopRecording()
            }
            return nil   // don't let the key do anything else
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording {
            isRecording = false
            onRecordingChange(false)
        }
    }
}

nonisolated extension KeyChord.Modifiers {
    init(nsFlags: NSEvent.ModifierFlags) {
        var m: KeyChord.Modifiers = []
        if nsFlags.contains(.command) { m.insert(.cmd) }
        if nsFlags.contains(.option)  { m.insert(.alt) }
        if nsFlags.contains(.control) { m.insert(.ctrl) }
        if nsFlags.contains(.shift)   { m.insert(.shift) }
        self = m
    }
}

/// Quick picks for the command field.
private struct CommandPresetMenu: View {
    let onPick: (String) -> Void

    private let directions = ["left", "down", "up", "right"]

    var body: some View {
        Menu {
            Section("Focus & move") {
                ForEach(directions, id: \.self) { d in Button("focus \(d)") { onPick("focus \(d)") } }
                ForEach(directions, id: \.self) { d in Button("move \(d)") { onPick("move \(d)") } }
                Menu("join-with") {
                    ForEach(directions, id: \.self) { d in
                        Button("join-with \(d)") { onPick("join-with \(d)") }
                        Button("join-with \(d); mode main") { onPick("join-with \(d); mode main") }
                    }
                }
            }
            Section("Workspaces") {
                Menu("workspace") {
                    ForEach(1...9, id: \.self) { n in Button("workspace \(n)") { onPick("workspace \(n)") } }
                    Button("workspace-back-and-forth") { onPick("workspace-back-and-forth") }
                    Button("workspace next") { onPick("workspace next") }
                    Button("workspace prev") { onPick("workspace prev") }
                }
                Menu("move-node-to-workspace") {
                    ForEach(1...9, id: \.self) { n in
                        Button("move-node-to-workspace \(n)") { onPick("move-node-to-workspace \(n)") }
                    }
                }
            }
            Section("Layout") {
                ForEach(["layout tiles horizontal vertical", "layout accordion horizontal vertical",
                         "layout tiles accordion", "layout floating tiling", "fullscreen",
                         "balance-sizes", "flatten-workspace-tree",
                         "resize smart +50", "resize smart -50"], id: \.self) { c in
                    Button(c) { onPick(c) }
                }
            }
            Section("Other") {
                ForEach(["mode main", "mode service", "reload-config", "close",
                         "close-all-windows-but-current", "volume up", "volume down",
                         "exec-and-forget open -a Terminal"], id: \.self) { c in
                    Button(c) { onPick(c) }
                }
            }
        } label: {
            Image(systemName: "text.badge.plus")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Insert a command")
    }
}

// MARK: - Border

struct BorderSettingsView: View {
    @Bindable var doc: ConfigDocument
    let model: AppModel

    var body: some View {
        Form {
            Section {
                ColorPicker("Focused window", selection: colorBinding(\.activeARGB), supportsOpacity: true)
                Toggle("Outline unfocused windows", isOn: inactiveEnabled)
                ColorPicker("Unfocused windows", selection: inactiveColor, supportsOpacity: true)
                    .disabled(doc.border.inactiveARGB == nil)
            } header: {
                Text("Colors")
            }

            Section {
                LabeledContent("Width") {
                    HStack {
                        Slider(value: $doc.border.width, in: 1...20, step: 1)
                        Text("\(Int(doc.border.width)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Corner radius") {
                    HStack {
                        Slider(value: $doc.border.cornerRadius, in: 0...30, step: 1)
                        Text("\(Int(doc.border.cornerRadius)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Shape")
            } footer: {
                Text("Corner radius should match your windows' corners; 0 draws square borders. Changes preview on your windows now and are kept when you Save.")
            }

            Section {
                HStack {
                    Text("Focused \(BorderStyle.hexString(doc.border.activeARGB))")
                    Spacer()
                    Text("Unfocused \(doc.border.inactiveARGB.map(BorderStyle.hexString) ?? "none")")
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

                Button("Reset to AeroSpace config colors") {
                    doc.border.activeARGB = 0xff6E_A3FE
                    doc.border.inactiveARGB = 0xff49_4D64
                    doc.border.width = 5
                }
            }

            if !model.isFocusBorderEnabled {
                Label("Built-in borders are switched off in the menu bar panel.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: doc.border) {
            model.previewBorder(doc.border)
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<BorderStyle, UInt32>) -> Binding<Color> {
        Binding(
            get: { Self.color(doc.border[keyPath: keyPath]) },
            set: { doc.border[keyPath: keyPath] = Self.argb($0) }
        )
    }

    private var inactiveColor: Binding<Color> {
        Binding(
            get: { Self.color(doc.border.inactiveARGB ?? 0xff49_4D64) },
            set: { doc.border.inactiveARGB = Self.argb($0) }
        )
    }

    private var inactiveEnabled: Binding<Bool> {
        Binding(
            get: { doc.border.inactiveARGB != nil },
            set: { doc.border.inactiveARGB = $0 ? 0xff49_4D64 : nil }
        )
    }

    static func color(_ argb: UInt32) -> Color {
        Color(.sRGB,
              red: Double((argb >> 16) & 0xff) / 255,
              green: Double((argb >> 8) & 0xff) / 255,
              blue: Double(argb & 0xff) / 255,
              opacity: Double((argb >> 24) & 0xff) / 255)
    }

    static func argb(_ color: Color) -> UInt32 {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 0xff6E_A3FE }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
        return byte(c.alphaComponent) << 24 | byte(c.redComponent) << 16
             | byte(c.greenComponent) << 8 | byte(c.blueComponent)
    }
}

// MARK: - Bar

struct BarSettingsView: View {
    @Bindable var doc: ConfigDocument
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Show bar", isOn: $doc.bar.enabled)
                Toggle("Keep tiled windows below the bar", isOn: $doc.bar.reserveSpace)
                Toggle("Draw over the macOS menu bar", isOn: $doc.bar.drawOverMenuBar)
                Toggle("Same height as the menu bar", isOn: $doc.bar.matchMenuBar)
                    .help("Matches the notch strip on displays with a notch, and the menu bar elsewhere.")
                LabeledContent("Height") {
                    HStack {
                        Slider(value: $doc.bar.height, in: 24...60, step: 1)
                        Text("\(Int(doc.bar.height)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(doc.bar.matchMenuBar)
                ColorPicker("Background", selection: argbBinding(\.backgroundARGB), supportsOpacity: true)
                Toggle("Blur behind the bar", isOn: $doc.bar.blur)
            } header: {
                Text("Bar")
            } footer: {
                Text("Like SketchyBar, the bar sits under the macOS menu bar unless “Draw over” is on — turn on System Settings › Control Center › “Automatically hide and show the menu bar” so it's visible. Right-click the bar for Settings.")
            }

            Section("Workspaces") {
                Toggle("Show workspaces", isOn: $doc.bar.showWorkspaces)
                Picker("Numbers", selection: $doc.bar.numerals) {
                    Text("Chinese (一 二 三)").tag(BarStyle.Numerals.chinese)
                    Text("Arabic (1 2 3)").tag(BarStyle.Numerals.arabic)
                }
                Picker("App icons", selection: $doc.bar.appIcons) {
                    Text(BarModel.hasAppFont ? "Automatic (sketchybar-app-font)" : "Automatic (app icons — app font not installed)")
                        .tag(BarStyle.AppIcons.automatic)
                    Text("sketchybar-app-font").tag(BarStyle.AppIcons.appFont)
                    Text("App icons").tag(BarStyle.AppIcons.appIcons)
                    Text("None").tag(BarStyle.AppIcons.none)
                }
                ColorPicker("Number color", selection: argbBinding(\.workspaceTextARGB), supportsOpacity: true)
                ColorPicker("Workspace background", selection: argbBinding(\.pillARGB), supportsOpacity: true)
                ColorPicker("Focused background", selection: argbBinding(\.focusedPillARGB), supportsOpacity: true)
                ColorPicker("Focused outline", selection: argbBinding(\.focusedOutlineARGB), supportsOpacity: true)
                LabeledContent("Focused outline width") {
                    HStack {
                        Slider(value: $doc.bar.focusedOutlineWidth, in: 0...5, step: 0.5)
                        Text(String(format: "%.1f pt", doc.bar.focusedOutlineWidth))
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
            }
            .disabled(!doc.bar.enabled)

            Section("Right side") {
                Toggle("Battery", isOn: $doc.bar.showBattery)
                Toggle("Volume", isOn: $doc.bar.showVolume)
                Toggle("Clock", isOn: $doc.bar.showClock)
                ColorPicker("Text color", selection: argbBinding(\.textARGB), supportsOpacity: true)
                TextField("Icon font", text: $doc.bar.iconFont)
                if !model.bar.model.hasIconFont {
                    Label("“\(doc.bar.iconFont)” isn't installed; using SF Symbols for icons.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $doc.bar.fontSize, in: 11...24, step: 1)
                        Text("\(Int(doc.bar.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            .disabled(!doc.bar.enabled)

            Section {
                Button("Reset to SketchyBar config") { doc.bar = BarStyle() }
            }
        }
        .formStyle(.grouped)
        .onChange(of: doc.bar) {
            model.applyBar(doc.bar)   // live preview; Save keeps it
        }
    }

    private func argbBinding(_ keyPath: WritableKeyPath<BarStyle, UInt32>) -> Binding<Color> {
        Binding(
            get: { BorderSettingsView.color(doc.bar[keyPath: keyPath]) },
            set: { doc.bar[keyPath: keyPath] = BorderSettingsView.argb($0) }
        )
    }
}
