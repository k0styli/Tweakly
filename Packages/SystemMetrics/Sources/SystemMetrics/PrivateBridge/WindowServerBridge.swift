import ApplicationServices
import Foundation
import os

/// PRIVATE INTERFACE. What the window switcher needs to know about windows and no public API reports.
/// Checked on macOS 27.2 on an M2. Symbols are looked up on first use, so nothing here costs anything while
/// the switcher is off, and a missing symbol only makes the matching function return nil:
///
/// - `SLSCopySpacesForWindows` tells a window on another Space or a minimized one (one Space or more) from a
///   background tab or one of the stand-ins every app owns (none), and a minimized window from one on another
///   Space. Without it the switcher lists only windows on screen.
/// - `_AXUIElementGetWindow` names the window behind an Accessibility element. Without it the window is matched
///   by title and frame, see `WindowMatcher`.
/// - `_AXUIElementCreateWithRemoteToken` reaches a window on another Space, which `kAXWindowsAttribute` leaves
///   out. Without it only the window's app can be brought forward, not the window.
public enum WindowServerBridge {
    /// Function pointers looked up once and never changed, which is what makes sharing them safe.
    private struct Symbols: @unchecked Sendable {
        typealias MainConnection = @convention(c) () -> Int32
        typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        typealias CreateElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

        let mainConnection: MainConnection?
        let copySpaces: CopySpaces?
        let getWindow: GetWindow?
        let createElement: CreateElement?

        init() {
            let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
            let services = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
            // Through `PrivateSymbols`, so a test can take each one away and check what is left without it.
            mainConnection = PrivateSymbols.find("SLSMainConnectionID", in: skyLight).map {
                unsafeBitCast($0, to: MainConnection.self)
            }
            copySpaces = PrivateSymbols.find("SLSCopySpacesForWindows", in: skyLight).map {
                unsafeBitCast($0, to: CopySpaces.self)
            }
            getWindow = PrivateSymbols.find("_AXUIElementGetWindow", in: services).map {
                unsafeBitCast($0, to: GetWindow.self)
            }
            createElement = PrivateSymbols.find("_AXUIElementCreateWithRemoteToken", in: services).map {
                unsafeBitCast($0, to: CreateElement.self)
            }
        }
    }

    private static let symbols = Symbols()
    /// All Spaces, whether current or not, as the window server's mask has it.
    private static let allSpacesMask: Int32 = 7
    /// The Space on screen, as the window server's mask has it.
    private static let currentSpaceMask: Int32 = 5
    /// A token's fixed part, which spells "coco" for Cocoa.
    private static let tokenMagic: UInt32 = 0x636f_636f
    /// An app's element numbers are small, and a window normally turns up well before this.
    private static let elementsToTry: UInt64 = 2000

    /// How many Spaces a window belongs to, or nil if the system cannot say.
    public static func spaceCount(of window: CGWindowID) -> Int? {
        guard let main = symbols.mainConnection, let copy = symbols.copySpaces else { return nil }
        // A "Copy" function hands over ownership, which Swift does not assume for a function pointer.
        guard let spaces = copy(main(), allSpacesMask, [NSNumber(value: window)] as CFArray)?.takeRetainedValue()
        else { return nil }
        return CFArrayGetCount(spaces)
    }

    /// Whether a window belongs to the Space on screen now. For a window out of sight, yes means it was put away
    /// by minimizing or hiding, and no means it just lives on another Space.
    public static func isOnCurrentSpace(_ window: CGWindowID) -> Bool? {
        guard let main = symbols.mainConnection, let copy = symbols.copySpaces else { return nil }
        guard let spaces = copy(main(), currentSpaceMask, [NSNumber(value: window)] as CFArray)?.takeRetainedValue()
        else { return nil }
        return CFArrayGetCount(spaces) > 0
    }

    /// The window number behind an Accessibility element, or nil if the system cannot say.
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let get = symbols.getWindow else { return nil }
        var window: CGWindowID = 0
        return get(element, &window) == .success && window != 0 ? window : nil
    }

    /// Looks through an app's elements for a window that `kAXWindowsAttribute` does not report, because it is on
    /// another Space. About 80 µs per element, so this belongs off the main thread, and only for the one window
    /// someone chose. Gives up at the deadline, so an unresponsive app cannot hold on to the switch.
    public static func hiddenWindowElement(
        of window: CGWindowID, in pid: pid_t, deadline: ContinuousClock.Instant
    ) -> AXUIElement? {
        guard let create = symbols.createElement, symbols.getWindow != nil else { return nil }
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { bytes in
            bytes.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            bytes.storeBytes(of: tokenMagic, toByteOffset: 8, as: UInt32.self)
        }
        for number in 0..<elementsToTry {
            if ContinuousClock.now > deadline { return nil }
            token.withUnsafeMutableBytes { $0.storeBytes(of: number, toByteOffset: 12, as: UInt64.self) }
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            if windowID(of: element) == window { return element }
        }
        return nil
    }
}
