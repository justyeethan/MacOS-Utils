import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps
import Observation

/// Clock, volume and battery for the bar, read natively instead of via SketchyBar's scripts
/// (`date`, the volume_change event, `pmset -g batt`).
@Observable
final class SystemStatus {
    private(set) var clock = ""
    private(set) var volume: Int?
    private(set) var isMuted = false
    private(set) var battery: Int?
    private(set) var isOnAC = false

    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let clockFormatter: DateFormatter = {
        // plugins/clock.sh: date '+%a %d %b   %I:%M %p'  →  "Tue 10 Nov   07:06 PM"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE dd MMM   hh:mm a"
        return f
    }()

    func start() {
        guard timers.isEmpty else { return }
        refreshClock(); refreshVolume(); refreshBattery()
        // Clock: check every second so the minute flips on time (only publishes on change).
        timers.append(Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { self.refreshClock(); self.refreshVolume() }
        })
        // battery.sh ran every 120s; 30s keeps the charging bolt responsive.
        timers.append(Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { self.refreshBattery() }
        })
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [unowned self] _ in
            MainActor.assumeIsolated { self.refreshClock(); self.refreshBattery() }
        }
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Call after changing volume ourselves so the bar updates immediately.
    func refreshVolume() {
        let v = Self.readVolume()
        if volume != v?.percent { volume = v?.percent }
        if isMuted != (v?.muted ?? false) { isMuted = v?.muted ?? false }
    }

    private func refreshClock() {
        let text = clockFormatter.string(from: Date())
        if text != clock { clock = text }
    }

    private func refreshBattery() {
        let b = Self.readBattery()
        if battery != b?.percent { battery = b?.percent }
        if isOnAC != (b?.onAC ?? false) { isOnAC = b?.onAC ?? false }
    }

    // MARK: CoreAudio

    private static func readVolume() -> (percent: Int, muted: Bool)? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddr,
                                         0, nil, &size, &device) == noErr, device != 0 else { return nil }

        var volumeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var level = Float32(0)
        size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &volumeAddr),
              AudioObjectGetPropertyData(device, &volumeAddr, 0, nil, &size, &level) == noErr else { return nil }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddr) {
            _ = AudioObjectGetPropertyData(device, &muteAddr, 0, nil, &size, &muted)
        }
        return (Int((level * 100).rounded()), muted != 0)
    }

    // MARK: IOKit power sources

    private static func readBattery() -> (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() else { return nil }
        for source in list as NSArray {
            guard let desc = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?
                    .takeUnretainedValue() as? [String: Any],
                  desc["Type"] as? String == "InternalBattery",
                  let current = desc["Current Capacity"] as? Int,
                  let max = desc["Max Capacity"] as? Int, max > 0 else { continue }
            let onAC = desc["Power Source State"] as? String == "AC Power"
            return (current * 100 / max, onAC)
        }
        return nil   // desktop Mac: no battery item
    }
}
