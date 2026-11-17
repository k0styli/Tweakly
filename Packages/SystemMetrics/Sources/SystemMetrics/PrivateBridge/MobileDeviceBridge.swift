import BatteryHealthCore
import CoreFoundation
import Darwin
import Foundation
import Synchronization

/// What an iPhone, iPad or iPod told this Mac about itself and its battery.
public struct MobileDeviceReport: Sendable {
    public enum Problem: Sendable {
        /// The device has not been told to trust this Mac: it asks when unlocked, or Finder pairs it.
        case notTrusted
        /// Connected, but it refused a session: usually locked since it was turned on.
        case locked
        /// Gone while being read, or a service that did not answer.
        case unreadable
    }

    /// The device's own identifier. Personal: the page keeps only a digest of it and it is never logged.
    public var identifier: String
    public var connection: Connection
    public var name: String?
    public var productType: String?
    public var systemVersion: String?
    public var reading: BatteryReading?
    /// Nil when they were not asked this time: a watch's charge moves slowly and asking costs a session of its own.
    public var watches: [PairedWatchReport]?
    public var problem: Problem?
}

/// An Apple Watch as the iPhone it is paired with describes it.
public struct PairedWatchReport: Sendable {
    public var identifier: String
    public var name: String?
    public var productType: String?
    public var systemVersion: String?
    public var reading: BatteryReading
}

/// PRIVATE INTERFACE. iPhones, iPads and iPods on a cable or on the same Wi-Fi, through MobileDevice, the framework
/// Finder syncs them with.
///
/// `AMDeviceNotificationSubscribe` reports devices as they come and go: a callback gets a structure with the device at
/// offset 0 and the message at offset 8 (1 connected, 2 gone). A device is read with a session, its lockdown values,
/// the `com.apple.mobile.battery` domain and the `com.apple.mobile.diagnostics_relay` service asked for the
/// `AppleSmartBattery` registry entry, as coconutBattery and libimobiledevice do; `com.apple.companion_proxy` lists the
/// Apple Watches paired with an iPhone. Checked on macOS 27.2 with an iPhone 15 Pro on iOS 27.2.1 by cable: a read takes
/// 150–230 ms, nearly all of it waiting for the phone. Loading the framework and subscribing took an empty process from
/// 1.5 to 3.5 MB and woke it never. A missing symbol or framework makes `init` fail and the page says so.
public final class MobileDevices: @unchecked Sendable {
    // Unchecked: the symbols never change after `init`; `subscription` and `attached` are touched only on the main
    // thread, where the framework calls back because the subscription is made there; a device is read, and
    // `watchesAsked` touched, only on `queue`.

    public enum Event: Sendable {
        case read(MobileDeviceReport)
        case gone(identifier: String)
    }

    private struct Symbols: @unchecked Sendable {
        // Unchecked: C function pointers looked up once and never changed.
        typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        typealias Subscribe =
            @convention(c) (
                Callback, UInt32, UInt32, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>
            ) -> Int32
        typealias DeviceCall = @convention(c) (UnsafeMutableRawPointer) -> Int32
        typealias Unsubscribe = @convention(c) (UnsafeMutableRawPointer) -> Int32
        typealias CopyValue =
            @convention(c) (UnsafeMutableRawPointer, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
        typealias CopyIdentifier = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFString>?
        typealias Retain = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        typealias Release = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias StartService =
            @convention(c) (
                UnsafeMutableRawPointer, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>
            ) -> Int32
        typealias Send = @convention(c) (UnsafeMutableRawPointer, CFPropertyList, Int) -> Int32
        typealias Receive =
            @convention(c) (
                UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>, UnsafeMutablePointer<Int>?
            )
            -> Int32
        typealias Invalidate = @convention(c) (UnsafeMutableRawPointer) -> Void

        let subscribe: Subscribe
        let unsubscribe: Unsubscribe
        let connect: DeviceCall
        let disconnect: DeviceCall
        let isPaired: DeviceCall
        let validatePairing: DeviceCall
        let startSession: DeviceCall
        let stopSession: DeviceCall
        let interfaceType: DeviceCall
        let copyValue: CopyValue
        let copyIdentifier: CopyIdentifier
        let retain: Retain
        let release: Release
        let startService: StartService
        let send: Send
        let receive: Receive
        let invalidate: Invalidate

        init?() {
            let path = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
            guard let library = dlopen(path, RTLD_LAZY) else { return nil }
            func find<T>(_ name: String, as: T.Type) -> T? {
                PrivateSymbols.find(name, in: library).map { unsafeBitCast($0, to: T.self) }
            }
            guard let subscribe = find("AMDeviceNotificationSubscribe", as: Subscribe.self),
                let unsubscribe = find("AMDeviceNotificationUnsubscribe", as: Unsubscribe.self),
                let connect = find("AMDeviceConnect", as: DeviceCall.self),
                let disconnect = find("AMDeviceDisconnect", as: DeviceCall.self),
                let isPaired = find("AMDeviceIsPaired", as: DeviceCall.self),
                let validatePairing = find("AMDeviceValidatePairing", as: DeviceCall.self),
                let startSession = find("AMDeviceStartSession", as: DeviceCall.self),
                let stopSession = find("AMDeviceStopSession", as: DeviceCall.self),
                let interfaceType = find("AMDeviceGetInterfaceType", as: DeviceCall.self),
                let copyValue = find("AMDeviceCopyValue", as: CopyValue.self),
                let copyIdentifier = find("AMDeviceCopyDeviceIdentifier", as: CopyIdentifier.self),
                let retain = find("AMDeviceRetain", as: Retain.self),
                let release = find("AMDeviceRelease", as: Release.self),
                let startService = find("AMDeviceSecureStartService", as: StartService.self),
                let send = find("AMDServiceConnectionSendMessage", as: Send.self),
                let receive = find("AMDServiceConnectionReceiveMessage", as: Receive.self),
                let invalidate = find("AMDServiceConnectionInvalidate", as: Invalidate.self)
            else { return nil }
            self.subscribe = subscribe
            self.unsubscribe = unsubscribe
            self.connect = connect
            self.disconnect = disconnect
            self.isPaired = isPaired
            self.validatePairing = validatePairing
            self.startSession = startSession
            self.stopSession = stopSession
            self.interfaceType = interfaceType
            self.copyValue = copyValue
            self.copyIdentifier = copyIdentifier
            self.retain = retain
            self.release = release
            self.startService = startService
            self.send = send
            self.receive = receive
            self.invalidate = invalidate
        }
    }

    /// A device as the framework hands it over, retained while it is attached.
    private struct Attached: @unchecked Sendable {
        // Unchecked: the pointer is retained for as long as a read uses it, and the framework's device calls may be
        // made from any thread, as Xcode makes them.
        let device: UnsafeMutableRawPointer
        let identifier: String
        let connection: Connection
    }

    /// An open session with a device and its diagnostics service, kept while the page shows: setting one up costs about
    /// 260 million instructions of TLS handshakes, a request over it 4 million and 11 ms (iPhone 15 Pro, iOS 27.2.1).
    /// A link that stops answering, as when the phone locks or goes away, is closed and set up again.
    private final class Link {
        /// Retained by the link.
        let device: UnsafeMutableRawPointer
        /// Retained once, as the framework hands it over.
        let diagnostics: UnsafeMutableRawPointer
        var name: String?
        var productType: String?
        var systemVersion: String?

        init(device: UnsafeMutableRawPointer, diagnostics: UnsafeMutableRawPointer) {
            self.device = device
            self.diagnostics = diagnostics
        }
    }

    /// Open links by device identifier. A class of its own so that `stop` can close them from a block that does not
    /// hold this object, which may be going away.
    private final class Links: @unchecked Sendable {
        // Unchecked: touched only on `queue`.
        var open: [String: Link] = [:]
    }

    private static let diagnosticsService = "com.apple.mobile.diagnostics_relay"

    /// The framework's interface types: 1 a cable, 2 the network.
    private static let usbInterface: Int32 = 1
    private static let connectedMessage: UInt32 = 1
    private static let goneMessage: UInt32 = 2
    private static let xmlFormat = 100

    private let symbols: Symbols
    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "me.tweakly.mobile-devices", qos: .utility)
    private let links = Links()
    private var subscription: UnsafeMutableRawPointer?
    /// While paused, devices are followed but not read and no link stays open.
    private var isPaused = false
    /// Each device can be attached twice, by cable and by Wi-Fi; the cable is read.
    private var attached: [Attached] = []
    /// When each iPhone's watches were last asked for, touched only on `queue`.
    private var watchesAsked: [String: TimeInterval] = [:]
    private static let watchInterval: TimeInterval = 300

    /// Starts listening, from the main thread: the framework calls back on the run loop it was subscribed from.
    /// Devices already connected are reported at once. Nil when the framework or one of its functions is missing.
    public init?(handler: @escaping @Sendable (Event) -> Void) {
        guard let symbols = Symbols() else {
            metricsLog.notice("MobileDevice is unavailable; iPhone and iPad batteries are not read")
            return nil
        }
        self.symbols = symbols
        self.handler = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        var subscription: UnsafeMutableRawPointer?
        let status = symbols.subscribe(Self.callback, 0, 0, context, &subscription)
        guard status == 0, let subscription else {
            metricsLog.notice("MobileDevice refused a subscription: \(status, privacy: .public)")
            return nil
        }
        self.subscription = subscription
    }

    deinit {
        stop()
    }

    /// Stops listening, closes every link and lets go of every device. Reads in flight finish on their own.
    public func stop() {
        if let subscription {
            _ = symbols.unsubscribe(subscription)
            self.subscription = nil
        }
        for device in attached { symbols.release(device.device) }
        attached = []
        closeLinks()
    }

    /// Reads every attached device again, once each, on a cable where it has one.
    public func refresh() {
        guard !isPaused else { return }
        for device in preferred() { read(device) }
    }

    /// Stops reading and closes every link, while still following devices as they come and go. The framework loses an
    /// `AMDevice` of 496 bytes with each unsubscription (a probe in C with no code of ours did the same on macOS 27.2),
    /// so a page that comes and goes pauses rather than subscribing anew.
    public func pause() {
        isPaused = true
        closeLinks()
    }

    public func resume() {
        isPaused = false
        refresh()
    }

    private func closeLinks() {
        let links = links
        let symbols = symbols
        queue.async {
            for link in links.open.values { Self.close(link, symbols) }
            links.open = [:]
        }
    }

    private static let callback: Symbols.Callback = { info, context in
        guard let info, let context else { return }
        let devices = Unmanaged<MobileDevices>.fromOpaque(context).takeUnretainedValue()
        let device = info.load(as: UnsafeMutableRawPointer?.self)
        let message = info.load(fromByteOffset: 8, as: UInt32.self)
        guard let device else { return }
        devices.handle(device: device, message: message)
    }

    private func handle(device: UnsafeMutableRawPointer, message: UInt32) {
        guard subscription != nil else { return }
        switch message {
        case Self.connectedMessage:
            guard let identifier = symbols.copyIdentifier(device)?.takeRetainedValue() as String?,
                !attached.contains(where: { $0.device == device })
            else { return }
            let connection: Connection = symbols.interfaceType(device) == Self.usbInterface ? .usb : .wifi
            _ = symbols.retain(device)
            attached.append(Attached(device: device, identifier: identifier, connection: connection))
            if !isPaused, let chosen = preferred().first(where: { $0.identifier == identifier }),
                chosen.device == device
            {
                read(chosen)
            }
        case Self.goneMessage:
            guard let index = attached.firstIndex(where: { $0.device == device }) else { return }
            let gone = attached.remove(at: index)
            symbols.release(gone.device)
            let links = links
            let symbols = symbols
            let handler = handler
            let isLast = !attached.contains { $0.identifier == gone.identifier }
            // On the queue, behind any read of this device already waiting there, so that its result cannot bring the
            // device back after it was reported gone.
            queue.async {
                if let link = links.open[gone.identifier], link.device == gone.device {
                    links.open[gone.identifier] = nil
                    Self.close(link, symbols)
                }
                if isLast { handler(.gone(identifier: gone.identifier)) }
            }
            if !isLast, !isPaused, let other = attached.first(where: { $0.identifier == gone.identifier }) {
                read(other)
            }
        default:
            break
        }
    }

    /// One entry per device, the cable before Wi-Fi.
    private func preferred() -> [Attached] {
        var chosen: [String: Attached] = [:]
        var order: [String] = []
        for device in attached {
            if let current = chosen[device.identifier] {
                if current.connection != .usb, device.connection == .usb { chosen[device.identifier] = device }
            } else {
                chosen[device.identifier] = device
                order.append(device.identifier)
            }
        }
        return order.compactMap { chosen[$0] }
    }

    private func read(_ device: Attached) {
        // Held for the read, as the device may be detached on the main thread meanwhile.
        _ = symbols.retain(device.device)
        queue.async { [self] in
            let report = report(of: device)
            symbols.release(device.device)
            // The system lists an iPhone on the same Wi-Fi even when it cannot be reached: on macOS 27.2 an iPhone 15
            // Pro on the cable was also listed by Wi-Fi, and connecting there gave "Could not connect to the device".
            // Such a device is away, not connected and broken.
            if device.connection == .wifi, report.problem == .unreadable {
                handler(.gone(identifier: device.identifier))
            } else {
                handler(.read(report))
            }
        }
    }

    /// A device read over its open link, or set up afresh when there is none or the link has broken.
    private func report(of attached: Attached) -> MobileDeviceReport {
        if let link = links.open[attached.identifier] {
            if link.device == attached.device, var report = quickReport(over: link, attached: attached) {
                askWatchesIfDue(&report, device: link.device)
                return report
            }
            links.open[attached.identifier] = nil
            Self.close(link, symbols)
            metricsLog.info("A device's kept session stopped answering and is set up again")
        }
        var report = fullReport(of: attached)
        if report.problem == nil, let link = links.open[attached.identifier] {
            askWatchesIfDue(&report, device: link.device)
        }
        return report
    }

    /// Connects, checks the pairing, starts a session and the diagnostics service, and keeps them open as a link.
    private func fullReport(of attached: Attached) -> MobileDeviceReport {
        let device = attached.device
        var report = MobileDeviceReport(identifier: attached.identifier, connection: attached.connection)
        guard symbols.connect(device) == 0 else {
            report.problem = .unreadable
            return report
        }
        guard symbols.isPaired(device) != 0, symbols.validatePairing(device) == 0 else {
            _ = symbols.disconnect(device)
            report.problem = .notTrusted
            return report
        }
        guard symbols.startSession(device) == 0 else {
            _ = symbols.disconnect(device)
            report.problem = .locked
            return report
        }
        var diagnostics: UnsafeMutableRawPointer?
        guard symbols.startService(device, Self.diagnosticsService as CFString, nil, &diagnostics) == 0,
            let diagnostics
        else {
            _ = symbols.stopSession(device)
            _ = symbols.disconnect(device)
            report.problem = .unreadable
            return report
        }
        _ = symbols.retain(device)
        let link = Link(device: device, diagnostics: diagnostics)
        link.name = value(device, key: "DeviceName") as? String
        link.productType = value(device, key: "ProductType") as? String
        link.systemVersion = value(device, key: "ProductVersion") as? String
        guard let quick = quickReport(over: link, attached: attached) else {
            Self.close(link, symbols)
            report.problem = .unreadable
            return report
        }
        links.open[attached.identifier] = link
        metricsLog.info("A device session was set up (\(attached.connection.rawValue, privacy: .public))")
        return quick
    }

    /// The battery domain and the registry entries over an open link: about 4 million instructions and 11 ms. Nil when
    /// the link no longer answers.
    private func quickReport(over link: Link, attached: Attached) -> MobileDeviceReport? {
        guard let registry = batteryRegistry(over: link.diagnostics) else { return nil }
        var report = MobileDeviceReport(identifier: attached.identifier, connection: attached.connection)
        report.name = link.name
        report.productType = link.productType
        report.systemVersion = link.systemVersion
        let domain = value(link.device, domain: "com.apple.mobile.battery", key: nil) as? [String: Any]
        var reading = MobileDeviceParser.reading(
            registry: registry.battery, batteryDomain: domain, productType: link.productType, date: Date())
        if let pack = registry.pack { PackParser.apply(pack: pack, to: &reading) }
        report.reading = reading
        return report
    }

    private func askWatchesIfDue(_ report: inout MobileDeviceReport, device: UnsafeMutableRawPointer) {
        let now = uptimeSeconds()
        guard MobileDeviceParser.kind(productType: report.productType) == .iPhone,
            now - (watchesAsked[report.identifier] ?? -.infinity) >= Self.watchInterval,
            let watches = watches(device)
        else { return }
        // Only an answer counts: a proxy that did not answer is asked again next time.
        watchesAsked[report.identifier] = now
        report.watches = watches
    }

    private func value(_ device: UnsafeMutableRawPointer, domain: String? = nil, key: String?) -> Any? {
        symbols.copyValue(device, domain as CFString?, key as CFString?)?.takeRetainedValue()
    }

    /// The battery's registry entry and its pack's in one exchange. `IOPMPowerSource` is the class the battery belongs
    /// to, for a device that names it otherwise. Nil when the service stopped answering.
    private func batteryRegistry(over connection: UnsafeMutableRawPointer)
        -> (battery: [String: Any]?, pack: [String: Any]?)?
    {
        func registry(_ reply: [String: Any]?) -> [String: Any]? {
            guard let reply, reply["Status"] as? String == "Success",
                let diagnostics = reply["Diagnostics"] as? [String: Any],
                let registry = diagnostics["IORegistry"] as? [String: Any], !registry.isEmpty
            else { return nil }
            return registry
        }
        let replies = exchange(
            connection,
            ["AppleSmartBattery", "AppleSmartBatteryPack"].map { ["Request": "IORegistry", "EntryClass": $0] })
        guard replies.count == 2 else { return nil }
        var battery = registry(replies[0])
        if battery == nil {
            let fallback = exchange(connection, [["Request": "IORegistry", "EntryClass": "IOPMPowerSource"]])
            guard fallback.count == 1 else { return nil }
            battery = registry(fallback[0])
        }
        return (battery, registry(replies[1]))
    }

    /// Apple Watches paired with this iPhone, asked through the companion proxy; nil when the proxy did not answer. An
    /// iPhone without one answers "NoPairedWatches".
    private func watches(_ device: UnsafeMutableRawPointer) -> [PairedWatchReport]? {
        guard
            let registry = ask(
                device, service: "com.apple.companion_proxy", messages: [["Command": "GetDeviceRegistry"]]
            ).first
        else { return nil }
        guard let watchIDs = registry["PairedDevicesArray"] as? [String] else {
            return registry["Error"] as? String == "NoPairedWatches" ? [] : nil
        }
        return watchIDs.compactMap { watchID in
            let keys = WatchParser.keys
            let replies = ask(
                device, service: "com.apple.companion_proxy",
                messages: keys.map {
                    ["Command": "GetValueFromRegistry", "GetValueGizmoUDIDKey": watchID, "GetValueKeyKey": $0]
                })
            var values: [String: Any] = [:]
            for reply in replies {
                guard let retrieved = reply["RetrievedValueDictionary"] as? [String: Any] else { continue }
                values.merge(retrieved) { new, _ in new }
            }
            guard let reading = WatchParser.reading(values, date: Date()) else { return nil }
            return PairedWatchReport(
                identifier: watchID, name: (values["DeviceName"] ?? values["Name"]) as? String,
                productType: values["ProductType"] as? String,
                systemVersion: values["ProductVersion"] as? String, reading: reading)
        }
    }

    /// Starts a service, sends each message and reads one reply to each, then closes it. Empty when the service cannot
    /// be started.
    private func ask(_ device: UnsafeMutableRawPointer, service: String, messages: [[String: Any]]) -> [[String: Any]] {
        var connection: UnsafeMutableRawPointer?
        guard symbols.startService(device, service as CFString, nil, &connection) == 0, let connection else {
            return []
        }
        defer {
            symbols.invalidate(connection)
            // The connection comes to the caller retained once.
            Unmanaged<AnyObject>.fromOpaque(connection).release()
        }
        return exchange(connection, messages)
    }

    /// Sends each message and reads one reply to each; a reply that does not come ends the exchange.
    private func exchange(_ connection: UnsafeMutableRawPointer, _ messages: [[String: Any]]) -> [[String: Any]] {
        Self.exchange(connection, messages, symbols)
    }

    private static func exchange(_ connection: UnsafeMutableRawPointer, _ messages: [[String: Any]], _ symbols: Symbols)
        -> [[String: Any]]
    {
        var replies: [[String: Any]] = []
        for message in messages {
            guard symbols.send(connection, message as CFDictionary, xmlFormat) == 0 else { break }
            var reply: Unmanaged<CFPropertyList>?
            guard symbols.receive(connection, &reply, nil) == 0,
                let dictionary = reply?.takeRetainedValue() as? [String: Any]
            else { break }
            replies.append(dictionary)
        }
        return replies
    }

    /// Says goodbye to the diagnostics service, lets go of it, ends the session and the connection.
    private static func close(_ link: Link, _ symbols: Symbols) {
        _ = exchange(link.diagnostics, [["Request": "Goodbye"]], symbols)
        symbols.invalidate(link.diagnostics)
        Unmanaged<AnyObject>.fromOpaque(link.diagnostics).release()
        _ = symbols.stopSession(link.device)
        _ = symbols.disconnect(link.device)
        symbols.release(link.device)
    }
}
