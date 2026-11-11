import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps
import Observation

/// Clock, volume and battery for the bar, read natively instead of via SketchyBar's scripts
/// (`date`, the volume_change event, `pmset -g batt`).
///
/// Event-driven, so an idle Mac isn't woken for nothing:
/// * clock — one timer firing on each minute boundary (plus on wake / clock or time-zone change)
/// * volume — CoreAudio property listeners on the default output device (and on which device
///   is the default)
/// * battery — an IOKit power-source notification, plus on wake
@Observable
final class SystemStatus {
    private(set) var clock = ""
    private(set) var volume: Int?
    private(set) var isMuted = false
    private(set) var battery: Int?
    private(set) var isOnAC = false

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var clockTimer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var audioListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var listenedDevice = AudioDeviceID(0)
    @ObservationIgnored private let clockFormatter: DateFormatter = {
        // plugins/clock.sh: date '+%a %d %b   %I:%M %p'  →  "Tue 10 Nov   07:06 PM"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE dd MMM   hh:mm a"
        return f
    }()

    func start() {
        guard !isStarted else { return }
        isStarted = true
        refreshClock(); refreshVolume(); refreshBattery()

        scheduleClock()
        startAudioListeners()
        startPowerSourceNotifications()

        // After sleep the minute timer is stale and the battery may have changed; if the user
        // changes the clock or time zone, re-align too.
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.didWakeNotification) { s in
            s.refreshBattery(); s.refreshVolume(); s.scheduleClock()
        }
        observe(.default, .NSSystemClockDidChange) { $0.scheduleClock() }
        observe(.default, .NSSystemTimeZoneDidChange) { $0.scheduleClock() }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        clockTimer?.invalidate(); clockTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        stopAudioListeners()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping (SystemStatus) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { handler(self) }
        }
        observers.append((center, token))
    }

    // MARK: Clock

    /// One wake-up per minute, landing just after the minute turns over.
    private func scheduleClock() {
        clockTimer?.invalidate()
        refreshClock()
        let now = Date()
        let nextMinute = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0),
                                                   matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: nextMinute.addingTimeInterval(0.05), interval: 60, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { self.refreshClock() }
        }
        timer.tolerance = 0.5   // lets macOS batch this with other wake-ups
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func refreshClock() {
        let text = clockFormatter.string(from: Date())
        if text != clock { clock = text }
    }

    // MARK: Volume (CoreAudio listeners)

    /// Call after changing volume ourselves; listeners normally keep this current.
    func refreshVolume() {
        let v = Self.readVolume()
        if volume != v?.percent { volume = v?.percent }
        if isMuted != (v?.muted ?? false) { isMuted = v?.muted ?? false }
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    private func startAudioListeners() {
        // Delivered on the main queue; one block for every property we watch.
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.followDefaultOutputDevice()   // no-op unless the device changed
                self.refreshVolume()
            }
        }
        audioListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &Self.defaultOutputAddress, DispatchQueue.main, listener)
        followDefaultOutputDevice()
    }

    /// (Re)attaches the volume/mute listeners to whichever device is the default output now —
    /// e.g. after plugging in headphones.
    private func followDefaultOutputDevice() {
        guard let listener = audioListener else { return }
        let device = Self.defaultOutputDevice() ?? 0
        guard device != listenedDevice else { return }
        detachDeviceListeners()
        listenedDevice = device
        guard device != 0 else { return }
        if AudioObjectHasProperty(device, &Self.volumeAddress) {
            AudioObjectAddPropertyListenerBlock(device, &Self.volumeAddress, DispatchQueue.main, listener)
        }
        if AudioObjectHasProperty(device, &Self.muteAddress) {
            AudioObjectAddPropertyListenerBlock(device, &Self.muteAddress, DispatchQueue.main, listener)
        }
    }

    private func detachDeviceListeners() {
        guard let listener = audioListener, listenedDevice != 0 else { return }
        AudioObjectRemovePropertyListenerBlock(listenedDevice, &Self.volumeAddress, DispatchQueue.main, listener)
        AudioObjectRemovePropertyListenerBlock(listenedDevice, &Self.muteAddress, DispatchQueue.main, listener)
        listenedDevice = 0
    }

    private func stopAudioListeners() {
        detachDeviceListeners()
        if let listener = audioListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &Self.defaultOutputAddress, DispatchQueue.main, listener)
        }
        audioListener = nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress,
                                         0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    private static func readVolume() -> (percent: Int, muted: Bool)? {
        guard let device = defaultOutputDevice() else { return nil }
        var level = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &volumeAddress),
              AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &level) == noErr else { return nil }

        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            _ = AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        }
        return (Int((level * 100).rounded()), muted != 0)
    }

    // MARK: Battery (IOKit notification)

    private func startPowerSourceNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceChanged, context)?
                .takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    fileprivate func refreshBattery() {
        let b = Self.readBattery()
        if battery != b?.percent { battery = b?.percent }
        if isOnAC != (b?.onAC ?? false) { isOnAC = b?.onAC ?? false }
    }

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

/// IOKit calls this on the main run loop whenever any power source changes (percentage,
/// plugged/unplugged).
private nonisolated func powerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    MainActor.assumeIsolated {
        Unmanaged<SystemStatus>.fromOpaque(context).takeUnretainedValue().refreshBattery()
    }
}
