import CoreGraphics
import Darwin

/// Optional access to the IOHIDEvent behind a CGEvent.
///
/// Some apps (WebKit/Safari in particular) read scroll deltas from the underlying IOHIDEvent
/// rather than the CGEvent fields, so flipping only the CGEvent fields leaves them scrolling
/// the old way. Scroll Reverser patches the IOHIDEvent too; this does the same.
///
/// These are private symbols, so they're looked up at runtime with `dlsym`. If a future
/// macOS removes them, `isAvailable` is false and the reverser keeps working on the
/// public CGEvent fields alone.
nonisolated enum IOHIDEventBridge {

    nonisolated enum Field: UInt32, Sendable {
        // IOHIDEventField = (kIOHIDEventTypeScroll << 16) | index; kIOHIDEventTypeScroll == 6
        case scrollX = 0x0006_0000
        case scrollY = 0x0006_0001
    }

    /// Owns one +1 reference to an IOHIDEventRef copied from a CGEvent. The CGEvent holds the
    /// same object, so writes here change the event that gets delivered.
    nonisolated final class Event {
        private let ref: UnsafeMutableRawPointer

        fileprivate init(ref: UnsafeMutableRawPointer) { self.ref = ref }

        deinit {
            Unmanaged<AnyObject>.fromOpaque(ref).release()
        }

        func value(for field: Field) -> Double {
            Symbols.shared.getFloat!(ref, field.rawValue)
        }

        func set(_ value: Double, for field: Field) {
            Symbols.shared.setFloat!(ref, field.rawValue, value)
        }
    }

    static var isAvailable: Bool { Symbols.shared.isComplete }

    static func event(for cgEvent: CGEvent) -> Event? {
        guard isAvailable else { return nil }
        let cgPtr = Unmanaged.passUnretained(cgEvent).toOpaque()
        guard let copied = Symbols.shared.copy!(cgPtr) else { return nil }
        return Event(ref: copied)
    }

    // MARK: - Symbol lookup
    //
    // Signatures use raw pointers rather than CF class types: CGEventRef and IOHIDEventRef are
    // both plain pointers at the C level, and raw pointers are always C-representable.

    /// `IOHIDEventRef CGEventCopyIOHIDEvent(CGEventRef)` — returns +1, or NULL.
    private typealias CopyFn     = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    /// `IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef, IOHIDEventField)`
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double
    /// `void IOHIDEventSetFloatValue(IOHIDEventRef, IOHIDEventField, IOHIDFloat)`
    private typealias SetFloatFn = @convention(c) (UnsafeMutableRawPointer, UInt32, Double) -> Void

    private nonisolated struct Symbols: @unchecked Sendable {
        let copy: CopyFn?
        let getFloat: GetFloatFn?
        let setFloat: SetFloatFn?

        var isComplete: Bool { copy != nil && getFloat != nil && setFloat != nil }

        static let shared = Symbols()

        private init() {
            // RTLD_DEFAULT: search every image already loaded (CoreGraphics, IOKit).
            let handle = UnsafeMutableRawPointer(bitPattern: -2)
            func load<T>(_ name: String, as _: T.Type) -> T? {
                guard let sym = dlsym(handle, name) else { return nil }
                return unsafeBitCast(sym, to: T.self)
            }
            copy     = load("CGEventCopyIOHIDEvent", as: CopyFn.self)
            getFloat = load("IOHIDEventGetFloatValue", as: GetFloatFn.self)
            setFloat = load("IOHIDEventSetFloatValue", as: SetFloatFn.self)
        }
    }
}
