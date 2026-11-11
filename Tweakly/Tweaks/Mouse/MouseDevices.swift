import Foundation
import IOKit
import IOKit.hidsystem
import MouseCore
import SystemMetrics
import os

/// The pointer's speed and acceleration, set on each mouse itself through the HID event system, the way System Settings
/// and LinearMouse do. The system then moves the pointer as it always does, so nothing of Tweakly sits between the mouse
/// and the pointer: no event tap, no work per movement, no added latency, at any polling rate.
///
/// The public client may not touch these two properties, so this goes through a passive one, a private call kept in
/// `HIDEventSystemClients`; it needs no permission. Without it the pointer stays as the system has it.
///
/// Only mice are touched; a trackpad has its own kind of acceleration and is left alone. What each mouse had is kept and
/// put back when the tweak goes off. A mouse plugged in later gets the same settings, on the system's notice.
final class MouseDevices {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "mouse")
    private static let linearKey = "HIDUseLinearScalingMouseAcceleration"
    private static let resolutionKey = "HIDPointerResolution"
    private static let accelerationKey = "HIDMouseAcceleration"
    private static let accelerationTypeKey = "HIDPointerAccelerationType"
    /// What the system assumes when a mouse does not say: 400 counts an inch.
    private static let defaultResolution: Double = 400
    /// The event system makes its record of a new mouse a moment after the device appears.
    private static let settleDelay: TimeInterval = 0.5

    /// What a mouse had before Tweakly changed it.
    private struct Original {
        let resolution: Double
        let linear: CFTypeRef?
        let acceleration: CFTypeRef?
    }

    private let client = HIDEventSystemClients.passive()
    private var originals: [UInt64: Original] = [:]
    private var settings = MouseSettings()
    private var notificationPort: IONotificationPortRef?
    private var arrivals: io_iterator_t = 0
    private var pendingApply: DispatchWorkItem?

    init() {
        if client == nil {
            Self.log.error("No passive HID client on this macOS, so the pointer stays as the system has it")
        } else {
            watchForMice()
        }
    }

    func apply(_ settings: MouseSettings) {
        self.settings = settings
        for service in mice() { apply(settings, to: service) }
    }

    /// Every mouse as it was, and nothing left watching.
    func stop() {
        for service in mice() { restore(service) }
        originals = [:]
        pendingApply?.cancel()
        pendingApply = nil
        if arrivals != 0 { IOObjectRelease(arrivals) }
        arrivals = 0
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
    }

    #if TWEAKLY_AUTOMATION
        /// For tests: each mouse's name and the values that matter, as the system reports them now.
        var state: [[String: Any]] {
            mice().map { service in
                [
                    "product": IOHIDServiceClientCopyProperty(service, kIOHIDProductKey as CFString) as? String ?? "",
                    "linear": Self.number(IOHIDServiceClientCopyProperty(service, Self.linearKey as CFString)) ?? -1,
                    "resolution": Self.fixed(IOHIDServiceClientCopyProperty(service, Self.resolutionKey as CFString))
                        ?? -1,
                    "acceleration": Self.fixed(
                        IOHIDServiceClientCopyProperty(service, Self.accelerationKey as CFString))
                        ?? -1,
                ]
            }
        }
    #endif

    // MARK: Devices

    /// Pointing devices with a mouse's acceleration, which leaves out trackpads.
    private func mice() -> [IOHIDServiceClient] {
        guard let client else { return [] }
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.filter { service in
            IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                && IOHIDServiceClientCopyProperty(service, Self.accelerationTypeKey as CFString) as? String
                    == Self.accelerationKey
        }
    }

    private func apply(_ settings: MouseSettings, to service: IOHIDServiceClient) {
        let id = Self.registryID(of: service)
        let original =
            originals[id]
            ?? Original(
                resolution: Self.fixed(IOHIDServiceClientCopyProperty(service, Self.resolutionKey as CFString))
                    ?? Self.defaultResolution,
                linear: IOHIDServiceClientCopyProperty(service, Self.linearKey as CFString),
                acceleration: IOHIDServiceClientCopyProperty(service, Self.accelerationKey as CFString))
        originals[id] = original
        set(service, Self.linearKey, NSNumber(value: settings.acceleration ? 0 : 1))
        set(
            service, Self.resolutionKey,
            Self.fixedNumber(PointerSpeed.resolution(original: original.resolution, speed: settings.speed)))
        // A new resolution takes effect when the acceleration is set again, as LinearMouse found.
        if let acceleration = original.acceleration { set(service, Self.accelerationKey, acceleration) }
    }

    private func restore(_ service: IOHIDServiceClient) {
        guard let original = originals[Self.registryID(of: service)] else { return }
        set(service, Self.linearKey, original.linear ?? NSNumber(value: Self.systemWantsLinear ? 1 : 0))
        set(service, Self.resolutionKey, Self.fixedNumber(original.resolution))
        if let acceleration = original.acceleration { set(service, Self.accelerationKey, acceleration) }
    }

    private func set(_ service: IOHIDServiceClient, _ key: String, _ value: CFTypeRef) {
        if !IOHIDServiceClientSetProperty(service, key as CFString, value) {
            Self.log.error("The system did not take \(key, privacy: .public) for a mouse")
        }
    }

    /// The system's own choice in Mouse settings, for a mouse that had no value of its own to go back to.
    private static var systemWantsLinear: Bool {
        CFPreferencesCopyAppValue("com.apple.mouse.linear" as CFString, kCFPreferencesAnyApplication) as? Bool ?? false
    }

    // MARK: Mice arriving

    /// The kernel's notice of a new HID device that is a mouse; no device is opened, so no permission is needed.
    private func watchForMice() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary
        matching[kIOHIDPrimaryUsagePageKey] = kHIDPage_GenericDesktop
        matching[kIOHIDPrimaryUsageKey] = kHIDUsage_GD_Mouse
        let callback: IOServiceMatchingCallback = { info, iterator in
            // Every notice has to be read through, or the next does not come.
            while case let object = IOIteratorNext(iterator), object != 0 { IOObjectRelease(object) }
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<MouseDevices>.fromOpaque(info).takeUnretainedValue().miceChanged()
            }
        }
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard
            IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching, callback, info, &arrivals)
                == KERN_SUCCESS
        else { return }
        // Arming the notice means reading what is already there.
        while case let object = IOIteratorNext(arrivals), object != 0 { IOObjectRelease(object) }
    }

    private func miceChanged() {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingApply = nil
                self.apply(self.settings)
            }
        }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    // MARK: Values

    private static func registryID(of service: IOHIDServiceClient) -> UInt64 {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
    }

    /// The HID system keeps these as 16.16 fixed point.
    private static func fixed(_ value: CFTypeRef?) -> Double? {
        (value as? NSNumber).map { $0.doubleValue / 65536 }
    }

    private static func fixedNumber(_ value: Double) -> NSNumber {
        NSNumber(value: Int64((value * 65536).rounded()))
    }

    private static func number(_ value: CFTypeRef?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
