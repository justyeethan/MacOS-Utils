import ApplicationServices
import CoreGraphics
import Foundation

/// The single private API (same as AeroSpace): maps an AX window element to its CGWindowID,
/// which — unlike AXUIElement — is a stable identity for the window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Thin, typed wrappers over the Accessibility C API. All calls are synchronous and can block
/// for up to the messaging timeout if the target app is busy.
///
/// Attribute names are written as literals ("AXWindows") rather than the kAX… constants to keep
/// the String/CFString bridging uniform.
enum AX {
    /// Cap how long one unresponsive app can block us (seconds). Applied system-wide.
    static func setGlobalTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }

    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: Read

    static func raw(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        raw(el, attr) as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let v = raw(el, attr), CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = raw(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        guard let v = raw(el, attr), CFGetTypeID(v) == CFArrayGetTypeID() else { return [] }
        return (v as? [AXUIElement]) ?? []
    }

    static func hasAttribute(_ el: AXUIElement, _ attr: String) -> Bool {
        raw(el, attr) != nil
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    static func position(_ el: AXUIElement) -> CGPoint? {
        guard let v = raw(el, "AXPosition"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ el: AXUIElement) -> CGSize? {
        guard let v = raw(el, "AXSize"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// Frame in AX (top-left origin, y down) global coordinates.
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = position(el), let s = size(el) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // MARK: Write

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(el, attr as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    @discardableResult
    static func setPosition(_ el: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let v = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(el, "AXPosition" as CFString, v) == .success
    }

    @discardableResult
    static func setSize(_ el: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let v = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(el, "AXSize" as CFString, v) == .success
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(el, action as CFString) == .success
    }
}
