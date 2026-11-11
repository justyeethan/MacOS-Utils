import AppKit
import ApplicationServices
import os

/// Snapshot of window-manager state for the UI.
struct WMStatus: Equatable {
    var isRunning = false
    var focusedWorkspace = ""
    var visibleWorkspaces: [String] = []
    var occupiedWorkspaces: [String] = []
    var allWorkspaces: [String] = []
    var mode = "main"
    var configSource = ""
    var configErrors: [String] = []
    var windowCount = 0
    /// Per-workspace detail for the bar (what `aerospace list-windows` gave SketchyBar).
    var workspaces: [WorkspaceInfo] = []

    struct AppRef: Equatable {
        var name: String
        var pid: pid_t
    }

    struct WorkspaceInfo: Equatable {
        var name: String
        /// Display it's shown on, or was last shown on.
        var monitorID: CGDirectDisplayID?
        var isVisible: Bool
        /// One entry per window, tiled windows in tree order then floating ones.
        var apps: [AppRef]
    }
}

/// AeroSpace-style tiling window manager.
///
/// * One tree per workspace (`Workspace`), laid out by `LayoutEngine`.
/// * **Virtual workspaces:** every monitor shows one workspace; windows of the others are parked
///   in a bottom corner of the screen. No macOS Spaces APIs, no SIP changes, no extra permissions
///   beyond Accessibility.
/// * State lives on the main actor. AX calls are synchronous and bounded by a global timeout.
///
/// Command handling is in `WindowManager+Commands.swift`.
final class WindowManager {

    var onStatusChange: ((WMStatus) -> Void)?
    private(set) var status = WMStatus() {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    // State shared with the commands extension (internal on purpose).
    var config = WMConfig()
    let hotkeys = HotkeyTap()
    let borders = BorderManager()
    /// Draw our own window borders instead of launching JankyBorders from the config.
    var isBorderEnabled = true {
        didSet {
            guard isBorderEnabled != oldValue, isRunning else { return }
            if isBorderEnabled { updateBorder() } else { borders.hideAll(); runBordersCommands() }
        }
    }
    /// Height of the built-in bar at the top of each display (taller on notched displays);
    /// tiled windows stay below it. Empty when the bar is off or not reserving space.
    var reservedTop: [CGDirectDisplayID: CGFloat] = [:] {
        didSet {
            guard reservedTop != oldValue, isRunning else { return }
            for w in windows.values { w.lastAppliedFrame = nil }
            applyLayout()
        }
    }
    /// When the built-in bar is on, don't also poke an external SketchyBar on workspace change.
    var isBuiltInBarEnabled = false
    /// Mode to restore after hotkeys were suspended (e.g. while recording a shortcut).
    private var modeBeforeSuspend: String?

    /// While we're switching workspaces / focusing, macOS briefly still reports the *old* app's
    /// window as focused. Reacting to that would switch straight back to the old workspace
    /// (the flicker). System focus changes are ignored until this time, then re-baselined.
    private var focusSyncSuppressedUntil = Date.distantPast
    /// Our own frame writes echo back as AXWindowMoved/Resized for a moment; don't mistake
    /// them for the user dragging.
    private var userMovesIgnoredUntil = Date.distantPast
    /// Apps whose AXEnhancedUserInterface we switched off for the current batch of writes.
    private var enhancedUIRestore: [pid_t: AXUIElement] = [:]
    private var enhancedUIChecked = Set<pid_t>()
    /// The app that was frontmost once our last workspace switch / focus change settled.
    /// On an empty workspace that app (now hidden) stays frontmost; focus reports from it are
    /// leftovers, not the user choosing a window, so they mustn't pull us to another workspace.
    private var settledFrontPID: pid_t?
    /// For the "[border]" debug log: only log when the outlined window changes.
    private var lastActiveBorderID: CGWindowID?
    var watchers: [pid_t: AppWatcher] = [:]
    var windows: [CGWindowID: WindowNode] = [:]
    var workspaces: [String: Workspace] = [:]
    var monitors: [Monitor] = []
    /// monitor → name of the workspace it shows
    var visible: [CGDirectDisplayID: String] = [:]
    var focusedMonitorID: CGDirectDisplayID?
    var focusedWindowID: CGWindowID?
    var previousWorkspace: String?

    private var lastNotifiedWorkspace: String?
    /// Last window macOS reported as focused; system focus events for the same window are ignored,
    /// so our own focus changes don't bounce back as "user switched windows".
    var lastSystemFocusedID: CGWindowID?
    private var isStartingUp = false
    private(set) var isRunning = false
    private var scanScheduled = false
    private var layoutScheduled = false
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var safetyTimer: Timer?
    private var mouseUpTimer: Timer?
    private var userResized = Set<CGWindowID>()
    private var userMoved = Set<CGWindowID>()

    static let log = Logger(subsystem: "MacOSUtils", category: "WM")

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        AX.setGlobalTimeout(1.0)

        config = WMConfig.load()
        borders.style = config.border ?? BorderStyle()
        monitors = Monitor.current()
        assignInitialWorkspaces()
        observeSystem()

        for app in NSWorkspace.shared.runningApplications { attach(app) }

        isStartingUp = true
        scanNow()
        isStartingUp = false
        syncFocusFromSystem()
        applyLayout()

        hotkeys.onCommands = { [unowned self] commands in
            Task { @MainActor in self.execute(commands) }
        }
        hotkeys.setBindings(config.modes)
        hotkeys.setMode("main")
        do { try hotkeys.start() } catch {
            Self.log.error("hotkey tap failed to start: \(String(describing: error), privacy: .public)")
        }

        for command in config.afterStartupCommands {
            if isBorderEnabled, case .execAndForget(let shell) = command, BorderStyle.isBordersCommand(shell) {
                continue   // the built-in border replaces JankyBorders
            }
            run(command)
        }

        // Safety net for missed AX notifications (a few apps don't send them reliably). Window
        // events, app launch/quit/activate and focus changes already trigger scans, so this only
        // catches stragglers. It queries *every* app — waking them all — so keep it rare, and give
        // macOS slack to batch it with other wake-ups.
        let safety = Timer(timeInterval: 30, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { self.scheduleScan() }
        }
        safety.tolerance = 10
        RunLoop.main.add(safety, forMode: .default)
        safetyTimer = safety

        notifyWorkspaceChangeIfNeeded()
        publishStatus()
    }

    /// Stops managing and puts every parked window back on screen, so nothing is lost.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        hotkeys.stop()
        borders.hideAll()
        safetyTimer?.invalidate(); safetyTimer = nil
        mouseUpTimer?.invalidate(); mouseUpTimer = nil
        for (center, token) in notificationTokens { center.removeObserver(token) }
        notificationTokens = []

        unparkAll()

        for w in watchers.values { w.invalidate() }
        watchers = [:]
        windows = [:]
        workspaces = [:]
        visible = [:]
        focusedWindowID = nil
        lastSystemFocusedID = nil
        settledFrontPID = nil
        lastNotifiedWorkspace = nil
        previousWorkspace = nil
        userResized = []
        userMoved = []
        status = WMStatus()
    }

    func reloadConfig() {
        config = WMConfig.load()
        borders.style = config.border ?? BorderStyle()
        hotkeys.setBindings(config.modes)
        for w in windows.values { w.lastAppliedFrame = nil }
        applyLayout()
    }

    // MARK: - Lookup helpers

    func workspace(named name: String) -> Workspace {
        if let ws = workspaces[name] { return ws }
        let orientation: Orientation
        switch config.defaultRootOrientation {
        case .horizontal: orientation = .horizontal
        case .vertical:   orientation = .vertical
        case .auto:       orientation = (focusedMonitor ?? monitors.first)?.autoOrientation ?? .horizontal
        }
        let ws = Workspace(name: name, rootOrientation: orientation, rootLayout: config.defaultRootLayout)
        workspaces[name] = ws
        return ws
    }

    var focusedMonitor: Monitor? {
        monitors.first { $0.id == focusedMonitorID } ?? monitors.first { $0.isMain } ?? monitors.first
    }

    var focusedWorkspace: Workspace {
        if let id = focusedMonitor?.id, let name = visible[id] { return workspace(named: name) }
        return workspace(named: config.workspaceNames.first ?? "1")
    }

    var focusedWindow: WindowNode? {
        focusedWindowID.flatMap { windows[$0] }
    }

    func monitor(id: CGDirectDisplayID?) -> Monitor? {
        guard let id else { return nil }
        return monitors.first { $0.id == id }
    }

    func monitorID(showing ws: Workspace) -> CGDirectDisplayID? {
        visible.first { $0.value == ws.name }?.key
    }

    func isVisible(_ ws: Workspace) -> Bool { monitorID(showing: ws) != nil }

    /// Monitor a workspace is on (if visible) or was last on, falling back to the main display.
    func homeMonitor(of ws: Workspace) -> Monitor? {
        monitor(id: monitorID(showing: ws)) ?? monitor(id: ws.monitorID)
            ?? monitors.first { $0.isMain } ?? monitors.first
    }

    // MARK: - Workspaces and monitors

    private func assignInitialWorkspaces() {
        visible = [:]
        let names = config.workspaceNames.isEmpty ? ["1"] : config.workspaceNames
        var used = Set<String>()
        let ordered = monitors.sorted { a, b in a.isMain != b.isMain ? a.isMain : a.index < b.index }
        for m in ordered {
            let name = names.first { !used.contains($0) } ?? "\(used.count + 1)"
            used.insert(name)
            visible[m.id] = name
            workspace(named: name).monitorID = m.id
        }
        focusedMonitorID = ordered.first?.id
    }

    /// Shows `ws` on a monitor; the workspace previously there becomes hidden (parked on next layout).
    func show(_ ws: Workspace, on monitorID: CGDirectDisplayID) {
        visible[monitorID] = ws.name
        ws.monitorID = monitorID
    }

    func setFocusedMonitor(_ id: CGDirectDisplayID?) {
        guard let id, id != focusedMonitorID else { return }
        focusedMonitorID = id
        for command in config.onFocusedMonitorChanged { run(command) }
    }

    private func screensChanged() {
        monitors = Monitor.current()
        let ids = Set(monitors.map(\.id))
        visible = visible.filter { ids.contains($0.key) }
        for m in monitors where visible[m.id] == nil {
            let shown = Set(visible.values)
            let candidates = config.workspaceNames + workspaces.keys.sorted()
            let name = candidates.first { !shown.contains($0) } ?? "\(shown.count + 1)"
            show(workspace(named: name), on: m.id)
        }
        if focusedMonitorID.map({ !ids.contains($0) }) ?? true {
            focusedMonitorID = monitors.first { $0.isMain }?.id ?? monitors.first?.id
        }
        for w in windows.values { w.lastAppliedFrame = nil }
        applyLayout()
    }

    /// Runs `exec-on-workspace-change` with AeroSpace's environment variable names, so
    /// existing SketchyBar setups keep working.
    func notifyWorkspaceChangeIfNeeded() {
        let current = focusedWorkspace.name
        guard current != lastNotifiedWorkspace else { return }
        let prev = lastNotifiedWorkspace ?? ""
        lastNotifiedWorkspace = current
        guard !config.execOnWorkspaceChange.isEmpty else { return }
        if isBuiltInBarEnabled, config.execOnWorkspaceChange.contains(where: { $0.contains("sketchybar") }) {
            return   // the built-in bar replaces SketchyBar
        }
        Exec.run(config.execOnWorkspaceChange, extraEnvironment: [
            "AEROSPACE_FOCUSED_WORKSPACE": current,
            "AEROSPACE_PREV_WORKSPACE": prev,
        ])
    }

    // MARK: - System observation

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handler(note) }
            }
            notificationTokens.append((center, token))
        }
        func app(_ note: Notification) -> NSRunningApplication? {
            note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        }

        on(ws, NSWorkspace.didLaunchApplicationNotification) { [unowned self] note in
            guard let a = app(note) else { return }
            self.attach(a)
            // Fresh apps create windows a moment after launch.
            self.scheduleScan()
            self.scheduleScan(after: 0.5)
            self.scheduleScan(after: 1.5)
        }
        on(ws, NSWorkspace.didTerminateApplicationNotification) { [unowned self] note in
            guard let a = app(note) else { return }
            self.detach(pid: a.processIdentifier)
            self.scheduleLayout()
        }
        on(ws, NSWorkspace.didActivateApplicationNotification) { [unowned self] _ in
            self.syncFocusFromSystem()
            self.updateBorder()
        }
        on(ws, NSWorkspace.didHideApplicationNotification) { [unowned self] _ in self.scheduleScan() }
        on(ws, NSWorkspace.didUnhideApplicationNotification) { [unowned self] _ in self.scheduleScan() }
        on(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [unowned self] _ in
            self.screensChanged()
        }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), watchers[pid] == nil else { return }
        let watcher = AppWatcher(app: app)
        watcher.onNotification = { [unowned self, unowned watcher] name, element in
            self.handleAX(name, element, from: watcher)
        }
        watcher.ensureObserver()
        watchers[pid] = watcher
    }

    private func detach(pid: pid_t) {
        guard let watcher = watchers.removeValue(forKey: pid) else { return }
        for node in windows.values where node.watcher === watcher { remove(node) }
        watcher.invalidate()
    }

    private func handleAX(_ name: String, _ element: AXUIElement, from watcher: AppWatcher) {
        guard isRunning else { return }
        switch name {
        case "AXWindowCreated":
            scheduleScan()
            scheduleScan(after: 0.3)   // subrole/size often settle just after creation
        case "AXUIElementDestroyed", "AXWindowMiniaturized", "AXWindowDeminiaturized":
            scheduleScan()
        case "AXFocusedWindowChanged", "AXMainWindowChanged":
            syncFocusFromSystem()
            updateBorder()
        case "AXWindowMoved", "AXWindowResized":
            // Keep outlines glued to their windows, including mid-drag.
            if let id = AX.windowID(element), let node = windows[id], !node.isParked { updateBorder() }
            windowChangedByUser(element, resized: name == "AXWindowResized")
        default:
            break
        }
    }

    // MARK: - Scanning windows

    func scheduleScan(after delay: Double = 0) {
        if delay > 0 {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                self.scheduleScan()
            }
            return
        }
        guard !scanScheduled else { return }
        scanScheduled = true
        Task { @MainActor in self.scanNow() }
    }

    /// Reconciles our model with every app's AX window list: registers new windows, drops
    /// closed/minimised ones, then lays out.
    func scanNow() {
        scanScheduled = false
        guard isRunning else { return }

        var seen = Set<CGWindowID>()
        var hiddenApps = Set<pid_t>()

        for (pid, watcher) in watchers {
            if !watcher.isObserving { watcher.ensureObserver() }
            if watcher.isHidden { hiddenApps.insert(pid); continue }

            for element in watcher.windows {
                guard let id = AX.windowID(element) else { continue }
                if AX.bool(element, "AXMinimized") == true || AX.bool(element, "AXFullScreen") == true { continue }
                if windows[id] != nil { seen.insert(id); continue }
                guard let kind = classify(element) else { continue }
                seen.insert(id)
                register(element, id: id, watcher: watcher, floating: kind == .floating)
            }
        }

        for (id, node) in windows where !seen.contains(id) && !hiddenApps.contains(node.watcher.pid) {
            remove(node)
        }
        scheduleLayout()
    }

    private enum WindowKind { case tiled, floating }

    /// Which windows to manage, and whether they tile. Standard, resizable windows with a
    /// fullscreen button tile; dialogs and fixed-size panels float; anything else is ignored.
    private func classify(_ el: AXUIElement) -> WindowKind? {
        guard AX.string(el, "AXRole") == "AXWindow" else { return nil }
        if let size = AX.size(el), size.width < 40 || size.height < 40 { return nil }
        switch AX.string(el, "AXSubrole") {
        case "AXStandardWindow":
            let resizable = AX.isSettable(el, "AXSize")
            let hasFullscreenButton = AX.hasAttribute(el, "AXFullScreenButton")
            return resizable && hasFullscreenButton ? .tiled : .floating
        case "AXDialog", "AXFloatingWindow", "AXSystemDialog", "AXSystemFloatingWindow":
            return .floating
        default:
            return nil
        }
    }

    private func register(_ element: AXUIElement, id: CGWindowID, watcher: AppWatcher, floating heuristicFloating: Bool) {
        let node = WindowNode(id: id, watcher: watcher, element: element)
        windows[id] = node
        watcher.observe(window: element, id: id)

        var target: Workspace = focusedWorkspace
        if isStartingUp, let frame = AX.frame(element),
           let m = monitors.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }),
           let name = visible[m.id] {
            // At startup, keep windows on the workspace of the monitor they're already on.
            target = workspace(named: name)
        }

        var floating = heuristicFloating
        let title = node.title
        for rule in config.windowRules where matches(rule, node, title: title) {
            for command in rule.commands {
                switch command {
                case .moveNodeToWorkspace(let name):
                    target = workspace(named: name)
                case .layout(let args):
                    if args.first == .floating { floating = true }
                    if args.first == .tiling || args.first == .tiles { floating = false }
                default:
                    break
                }
            }
            if !rule.checkFurtherCallbacks { break }
        }

        let anchor = target === focusedWorkspace ? focusedWindow : target.lastFocused
        target.add(node, floating: floating, after: floating ? nil : anchor)
        if floating { node.floatingFrame = AX.frame(element) }
    }

    private func matches(_ rule: WMConfig.WindowRule, _ node: WindowNode, title: String) -> Bool {
        if let id = rule.appID, id != node.watcher.bundleID { return false }
        if let re = rule.appNameRegex,
           node.watcher.name.range(of: re, options: [.regularExpression, .caseInsensitive]) == nil { return false }
        if let re = rule.windowTitleRegex,
           title.range(of: re, options: [.regularExpression, .caseInsensitive]) == nil { return false }
        if let startup = rule.duringStartup, startup != isStartingUp { return false }
        return true
    }

    func remove(_ node: WindowNode) {
        node.workspace?.detach(node)
        windows[node.id] = nil
        node.watcher.forget(windowID: node.id)
        userResized.remove(node.id)
        userMoved.remove(node.id)
        if focusedWindowID == node.id { focusedWindowID = nil }
    }

    // MARK: - Focus

    /// Follows focus changes made outside the WM (clicks, Cmd-Tab, Dock). If the newly focused
    /// window lives on a hidden workspace, that workspace is brought up — same as AeroSpace.
    func syncFocusFromSystem() {
        guard isRunning, Date() >= focusSyncSuppressedUntil,
              let front = NSWorkspace.shared.frontmostApplication,
              let watcher = watchers[front.processIdentifier],
              let element = watcher.focusedWindow,
              let id = AX.windowID(element),
              id != lastSystemFocusedID else { return }
        lastSystemFocusedID = id
        guard let node = windows[id], let ws = node.workspace else { return }

        // Sitting on an empty workspace, the app we switched away from is still frontmost and may
        // shuffle its (hidden) windows' focus. Only a real app switch — Cmd-Tab, Dock, a click on
        // another app — should take us to a hidden workspace.
        if !isVisible(ws), focusedWindow == nil, front.processIdentifier == settledFrontPID {
            return
        }

        if !isVisible(ws), let mid = focusedMonitor?.id {
            previousWorkspace = focusedWorkspace.name
            suppressFocusSync()
            show(ws, on: mid)
            applyLayout()
        }
        noteFocus(node)
        notifyWorkspaceChangeIfNeeded()
        publishStatus()
    }

    /// Updates the model's notion of focus without touching macOS.
    func noteFocus(_ node: WindowNode) {
        focusedWindowID = node.id
        guard let ws = node.workspace else { return }
        ws.noteFocused(node)
        setFocusedMonitor(monitorID(showing: ws))
    }

    /// Focuses a window for real: raise it and make its app frontmost.
    func focus(_ node: WindowNode) {
        suppressFocusSync()
        noteFocus(node)
        lastSystemFocusedID = node.id
        AX.set(node.watcher.element, "AXFrontmost", true)
        AX.set(node.element, "AXMain", true)
        AX.perform(node.element, "AXRaise")
        _ = node.watcher.app.activate()
        updateBorder()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            self.updateBorder()
        }
    }

    /// Ignore system focus reports for a moment while our own focus change / workspace switch
    /// settles, then accept whatever macOS ended up focusing as the new baseline.
    func suppressFocusSync(for seconds: Double = 0.35) {
        focusSyncSuppressedUntil = Date().addingTimeInterval(seconds)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds + 0.05))
            self.rebaseSystemFocus()
        }
    }

    private func rebaseSystemFocus() {
        guard isRunning, Date() >= focusSyncSuppressedUntil else { return }   // a newer suppression is pending
        settledFrontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication,
              let watcher = watchers[front.processIdentifier],
              let element = watcher.focusedWindow,
              let id = AX.windowID(element) else { updateBorder(); return }
        lastSystemFocusedID = id
        // If the user clicked another window on a *visible* workspace meanwhile, follow it.
        // A window on a hidden workspace is just stale focus from before the switch: ignore it.
        if let node = windows[id], let ws = node.workspace, isVisible(ws), node.id != focusedWindowID {
            noteFocus(node)
            notifyWorkspaceChangeIfNeeded()
            publishStatus()
        }
        updateBorder()
    }

    // MARK: - Focus border

    /// Active colour on the focused window, inactive colour on every other visible window.
    /// The focused window only gets the active colour while its app is actually in front (or
    /// our own settings window is, so border edits preview live).
    func updateBorder() {
        guard isRunning, isBorderEnabled else { borders.hideAll(); return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier

        var active: (id: CGWindowID, frame: CGRect)?
        if let node = focusedWindow, !node.isParked, !node.watcher.isHidden,
           front == node.watcher.pid || front == getpid(),
           let frame = AX.frame(node.element) {
            active = (node.id, frame)
        }

        var inactive: [(id: CGWindowID, frame: CGRect)] = []
        if borders.showsInactive {
            for name in Set(visible.values) {
                for w in workspace(named: name).allWindows
                where w.id != active?.id && !w.isParked && !w.watcher.isHidden {
                    if let frame = AX.frame(w.element) { inactive.append((w.id, frame)) }
                }
            }
        }
        borders.update(active: active, inactive: inactive)

        if active?.id != lastActiveBorderID {
            lastActiveBorderID = active?.id
            Self.log.debug("[border] active=\(active.map { String($0.id) } ?? "none", privacy: .public) model=\(self.focusedWindowID.map { String($0) } ?? "none", privacy: .public) frontPID=\(front.map { String($0) } ?? "none", privacy: .public)")
        }
    }

    /// Live preview from the settings window, before saving.
    func previewBorder(_ style: BorderStyle) {
        borders.style = style
        updateBorder()
    }

    /// Stops hotkeys matching (so the settings window can record any chord), then restores the mode.
    func setHotkeysSuspended(_ suspended: Bool) {
        if suspended {
            if modeBeforeSuspend == nil { modeBeforeSuspend = hotkeys.currentMode }
            hotkeys.setMode("__suspended__")
        } else {
            hotkeys.setMode(modeBeforeSuspend ?? "main")
            modeBeforeSuspend = nil
        }
    }

    /// When the built-in border is switched off, fall back to JankyBorders from the config.
    private func runBordersCommands() {
        for case .execAndForget(let shell) in config.afterStartupCommands where BorderStyle.isBordersCommand(shell) {
            Exec.shell(shell)
        }
    }

    // MARK: - User drags and resizes

    private func windowChangedByUser(_ element: AXUIElement, resized: Bool) {
        guard Date() >= userMovesIgnoredUntil,
              let id = AX.windowID(element), let node = windows[id],
              !node.isFloating, !node.isParked,
              let applied = node.lastAppliedFrame,
              let frame = AX.frame(element),
              !Self.approximatelyEqual(frame, applied) else { return }   // our own move echoing back
        if resized { userResized.insert(id) } else { userMoved.insert(id) }
        waitForMouseUp()
    }

    /// Acts on drags/resizes once the button is released, so we don't fight the user mid-drag.
    private func waitForMouseUp() {
        guard mouseUpTimer == nil else { return }
        mouseUpTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [unowned self] timer in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                timer.invalidate()
                self.mouseUpTimer = nil
                self.applyUserChanges()
            }
        }
    }

    private func applyUserChanges() {
        // Resizes become new weights along the parent's axis.
        for id in userResized {
            guard let node = windows[id], let parent = node.parent,
                  let old = node.lastAppliedFrame, let new = AX.frame(node.element) else { continue }
            let horizontal = parent.orientation == .horizontal
            let oldLen = horizontal ? old.width : old.height
            let newLen = horizontal ? new.width : new.height
            if oldLen > 1, abs(newLen - oldLen) > 2 {
                node.weight = max(0.05, node.weight * newLen / oldLen)
            }
        }
        // A tiled window dragged onto another monitor moves to that monitor's workspace;
        // otherwise it snaps back into its tile.
        for id in userMoved where !userResized.contains(id) {
            guard let node = windows[id], let ws = node.workspace, let frame = AX.frame(node.element) else { continue }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let m = monitors.first(where: { $0.frame.contains(center) }),
               m.id != monitorID(showing: ws), let name = visible[m.id] {
                workspace(named: name).add(node, floating: false)
                noteFocus(node)
            }
        }
        for id in userResized.union(userMoved) { windows[id]?.lastAppliedFrame = nil }
        userResized = []
        userMoved = []
        applyLayout()
        notifyWorkspaceChangeIfNeeded()
    }

    // MARK: - Layout

    func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        Task { @MainActor in self.applyLayout() }
    }

    /// Lays out every visible workspace and parks every window of the hidden ones.
    func applyLayout() {
        layoutScheduled = false
        guard isRunning else { return }
        var wrote = false
        defer {
            endWriteBatch()
            if wrote { userMovesIgnoredUntil = Date().addingTimeInterval(0.5) }
            updateBorder()
            publishStatus()
        }

        // Hide the outgoing workspace first, so old and new windows never overlap on screen.
        let shown = Set(visible.values)
        for ws in workspaces.values where !shown.contains(ws.name) {
            ws.normalize(flatten: config.flattenContainers, oppositeOrientation: config.oppositeOrientationForNested)
            guard let home = homeMonitor(of: ws) else { continue }
            for node in ws.allWindows where !node.isParked {
                park(node, on: home)
                wrote = true
            }
        }

        for (mid, name) in visible {
            guard let monitor = monitor(id: mid) else { continue }
            let ws = workspace(named: name)
            ws.normalize(flatten: config.flattenContainers, oppositeOrientation: config.oppositeOrientationForNested)

            let gaps = ResolvedGaps(config.gaps, monitor: monitor, all: monitors)
            var usable = monitor.visibleFrame
            // visibleFrame already excludes the menu bar / notch strip; the bar may reach lower.
            let barBottom = monitor.frame.minY + (reservedTop[mid] ?? 0)
            if usable.minY < barBottom {
                usable.size.height -= barBottom - usable.minY
                usable.origin.y = barBottom
            }
            let rect = gaps.workspaceRect(in: usable)
            for (node, frame) in LayoutEngine.frames(for: ws, in: rect, gaps: gaps, accordionPadding: config.accordionPadding) {
                if node.watcher.isHidden { continue }
                let unchanged = node.lastAppliedFrame.map { Self.approximatelyEqual($0, frame) } ?? false
                if node.isParked || !unchanged {
                    setFrame(node, frame)
                    wrote = true
                }
                node.isParked = false
            }
            for node in ws.floating where node.isParked {
                restoreFloating(node, on: monitor)
                wrote = true
            }
            if let f = focusedWindow, f.workspace === ws, f.isFullscreen || f.parent?.layout == .accordion {
                AX.perform(f.element, "AXRaise")
            }
        }
    }

    // MARK: - Frame writes

    /// Some apps (notably browsers) animate every AX move — the slide to the corner — or ignore
    /// it while AXEnhancedUserInterface is on. Switch it off once per app for a batch of writes,
    /// and restore it in `endWriteBatch()`.
    private func prepareWrite(_ node: WindowNode) {
        let pid = node.watcher.pid
        guard !enhancedUIChecked.contains(pid) else { return }
        enhancedUIChecked.insert(pid)
        let app = node.watcher.element
        if AX.bool(app, "AXEnhancedUserInterface") == true {
            AX.set(app, "AXEnhancedUserInterface", false)
            enhancedUIRestore[pid] = app
        }
    }

    private func endWriteBatch() {
        for app in enhancedUIRestore.values { AX.set(app, "AXEnhancedUserInterface", true) }
        enhancedUIRestore = [:]
        enhancedUIChecked = []
    }

    private func setFrame(_ node: WindowNode, _ frame: CGRect) {
        prepareWrite(node)
        // size → position → size: the first size lets the move land when crossing screen edges,
        // the second fixes any clamping the move caused.
        AX.setSize(node.element, frame.size)
        AX.setPosition(node.element, frame.origin)
        AX.setSize(node.element, frame.size)
        node.lastAppliedFrame = frame
    }

    private func park(_ node: WindowNode, on monitor: Monitor) {
        let current = AX.frame(node.element)
        if node.isFloating { node.floatingFrame = current }
        let size = current?.size ?? CGSize(width: 800, height: 600)
        prepareWrite(node)
        AX.setPosition(node.element, monitor.parkingOrigin(for: size, among: monitors))
        node.isParked = true
        node.lastAppliedFrame = nil
    }

    private func restoreFloating(_ node: WindowNode, on monitor: Monitor) {
        var frame = node.floatingFrame ?? CGRect(origin: .zero, size: AX.size(node.element) ?? CGSize(width: 800, height: 600))
        if !monitor.visibleFrame.intersects(frame) {
            frame.origin = CGPoint(x: monitor.visibleFrame.midX - frame.width / 2,
                                   y: monitor.visibleFrame.midY - frame.height / 2)
        }
        prepareWrite(node)
        AX.setPosition(node.element, frame.origin)
        node.isParked = false
    }

    /// On quit: bring every parked window back onto the focused monitor, cascaded.
    private func unparkAll() {
        guard let target = focusedMonitor else { return }
        defer { endWriteBatch() }
        var offset: CGFloat = 0
        for node in windows.values where node.isParked {
            prepareWrite(node)
            let size = AX.size(node.element) ?? CGSize(width: 800, height: 600)
            let origin = CGPoint(x: target.visibleFrame.minX + 40 + offset,
                                 y: target.visibleFrame.minY + 40 + offset)
            AX.setSize(node.element, CGSize(width: min(size.width, target.visibleFrame.width - 80),
                                            height: min(size.height, target.visibleFrame.height - 80)))
            AX.setPosition(node.element, origin)
            node.isParked = false
            offset = (offset + 30).truncatingRemainder(dividingBy: 300)
        }
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Status

    func publishStatus() {
        let occupied = workspaces.values.filter { !$0.isEmpty }.map(\.name)
        let shown = Array(Set(visible.values))
        let all = Array(Set(config.workspaceNames + occupied + shown))
        status = WMStatus(
            isRunning: isRunning,
            focusedWorkspace: isRunning ? focusedWorkspace.name : "",
            visibleWorkspaces: Self.sortNames(shown),
            occupiedWorkspaces: Self.sortNames(occupied),
            allWorkspaces: Self.sortNames(all),
            mode: hotkeys.currentMode,
            configSource: config.source,
            configErrors: config.errors,
            windowCount: windows.count,
            workspaces: workspaces.values.map { ws in
                WMStatus.WorkspaceInfo(
                    name: ws.name,
                    monitorID: monitorID(showing: ws) ?? ws.monitorID,
                    isVisible: isVisible(ws),
                    apps: ws.allWindows.map { .init(name: $0.watcher.name, pid: $0.watcher.pid) })
            }.sorted { Self.nameOrder($0.name, $1.name) }
        )
    }

    static func sortNames(_ names: [String]) -> [String] {
        names.sorted(by: nameOrder)
    }

    /// Numeric workspaces in number order, then named ones alphabetically.
    static func nameOrder(_ a: String, _ b: String) -> Bool {
        switch (Int(a), Int(b)) {
        case let (x?, y?): x < y
        case (_?, nil):    true
        case (nil, _?):    false
        default:           a < b
        }
    }
}
