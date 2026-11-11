import AppKit
import ApplicationServices
import Observation

/// App-wide state on the main actor. Owns the input services and persists settings.
///
/// Owns both features — scroll reversal and the tiling window manager — which share the single
/// Accessibility permission.
@MainActor
@Observable
final class AppModel {

    var scrollSettings: ScrollSettings {
        didSet {
            guard scrollSettings != oldValue else { return }
            scrollStore.replace(with: scrollSettings)
            Self.save(scrollSettings)
        }
    }

    private(set) var isAccessibilityTrusted = false
    private(set) var isScrollTapRunning = false
    /// Most recently detected scroll source, for showing in the UI.
    private(set) var lastScrollSource: ScrollSource?

    /// Tiling window manager on/off (persisted).
    var isWindowManagerEnabled: Bool = UserDefaults.standard.object(forKey: "WMEnabled") as? Bool ?? true {
        didSet {
            guard isWindowManagerEnabled != oldValue else { return }
            UserDefaults.standard.set(isWindowManagerEnabled, forKey: "WMEnabled")
            if isWindowManagerEnabled { if isAccessibilityTrusted { windowManager.start() } }
            else { windowManager.stop() }
        }
    }
    /// Built-in focus border instead of JankyBorders (persisted).
    var isFocusBorderEnabled: Bool = UserDefaults.standard.object(forKey: "WMFocusBorder") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(isFocusBorderEnabled, forKey: "WMFocusBorder")
            windowManager.isBorderEnabled = isFocusBorderEnabled
        }
    }
    private(set) var wmStatus = WMStatus()

    /// Editable config for the settings window (bindings + borders).
    let configDocument = ConfigDocument()
    private(set) var configSaveError: String?
    var confirmUseAeroSpaceConfig = false

    @ObservationIgnored let windowManager = WindowManager()
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?
    @ObservationIgnored private let scrollStore: ScrollSettingsStore
    @ObservationIgnored private let scrollTap: ScrollEventTap
    @ObservationIgnored private var trustPoll: Timer?

    init() {
        let settings = Self.load()
        scrollSettings = settings
        scrollStore = ScrollSettingsStore(settings)
        scrollTap = ScrollEventTap(settings: scrollStore)
        // `unowned`: the model lives as long as the app, and unowned (unlike weak) is a
        // plain constant capture, which @Sendable closures accept without complaint.
        scrollTap.onSourceChange = { [unowned self] source in
            Task { @MainActor in self.lastScrollSource = source }
        }
        windowManager.onStatusChange = { [unowned self] status in self.wmStatus = status }
        windowManager.isBorderEnabled = isFocusBorderEnabled
        // Put parked windows back on screen however the app quits (Quit button, Cmd-Q, logout).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [unowned self] _ in
            MainActor.assumeIsolated { self.stopAll() }
        }
        startWhenTrusted(prompt: false)
    }

    // MARK: - Permissions

    /// Shows the system "allow Accessibility" prompt (once per launch at most), then polls until
    /// the user flips the switch. macOS doesn't post a notification when trust changes.
    func requestAccessibility() {
        startWhenTrusted(prompt: true)
    }

    /// Clears this app's stale Accessibility entry and asks again.
    ///
    /// Accessibility trust is tied to the code signature. Each ad-hoc-signed Xcode build has a
    /// new signature, so System Settings keeps showing the *old* build as allowed while the
    /// new one is untrusted — and macOS won't show the prompt again while an entry exists.
    /// `tccutil reset` removes the entry so the prompt can appear for this build.
    func resetAccessibilityPermission() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let tccutil = Process()
        tccutil.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tccutil.arguments = ["reset", "Accessibility", bundleID]
        do {
            try tccutil.run()
            tccutil.waitUntilExit()
        } catch {
            NSLog("MacOSUtils: tccutil reset failed: \(error)")
        }
        startWhenTrusted(prompt: true)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startWhenTrusted(prompt: Bool) {
        isAccessibilityTrusted = Self.checkTrust(prompt: prompt)
        if isAccessibilityTrusted {
            startServices()
            return
        }
        guard trustPoll == nil else { return }
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                guard Self.checkTrust(prompt: false) else { return }
                self.trustPoll?.invalidate()
                self.trustPoll = nil
                self.isAccessibilityTrusted = true
                self.startServices()
            }
        }
    }

    private static func checkTrust(prompt: Bool) -> Bool {
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt; the
        // literal avoids touching a non-Sendable C global under strict concurrency.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    // MARK: - Services

    private func startServices() {
        startScrollTap()
        if isWindowManagerEnabled { windowManager.start() }
    }

    func reloadWindowManagerConfig() {
        windowManager.reloadConfig()
    }

    func switchWorkspace(_ name: String) {
        windowManager.execute([.workspace(name)])
    }

    // MARK: - Settings window

    func saveConfig() {
        do {
            try configDocument.save()
            configSaveError = nil
            windowManager.reloadConfig()
        } catch {
            configSaveError = error.localizedDescription
        }
    }

    func revertConfig() {
        configDocument.revert()
        configSaveError = nil
        windowManager.previewBorder(configDocument.border)
    }

    func useAeroSpaceConfig() {
        do {
            try configDocument.useAeroSpaceConfig()
            configSaveError = nil
            windowManager.reloadConfig()
        } catch {
            configSaveError = error.localizedDescription
        }
    }

    func previewBorder(_ style: BorderStyle) {
        windowManager.previewBorder(style)
    }

    func setHotkeysSuspended(_ suspended: Bool) {
        windowManager.setHotkeysSuspended(suspended)
    }

    private func startScrollTap() {
        guard !scrollTap.isRunning else { isScrollTapRunning = true; return }
        do {
            try scrollTap.start()
            isScrollTapRunning = true
        } catch {
            isScrollTapRunning = false
            NSLog("MacOSUtils: could not start scroll tap: \(error)")
        }
    }

    func stopAll() {
        windowManager.stop()   // restores parked windows first
        scrollTap.stop()
        isScrollTapRunning = false
    }

    // MARK: - Persistence

    private static let defaultsKey = "ScrollSettings.v1"

    private static func load() -> ScrollSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(ScrollSettings.self, from: data)
        else { return ScrollSettings() }
        return settings
    }

    private static func save(_ settings: ScrollSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
