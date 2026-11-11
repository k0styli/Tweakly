import Darwin
import Foundation
import SystemConfiguration

final class NetworkSampler: MetricSampler {
    /// Which interface is primary rarely changes, and finding out involves several system calls.
    private static let interfaceRefreshInterval: TimeInterval = 5

    /// The physical interfaces, by index, found the last time the number of interfaces changed.
    private var physicalInterfaces: [Int32] = []
    private var knownInterfaceCount: Int32 = -1
    private var traffic = TrafficCounter()
    private var lastRates: (down: Double, up: Double) = (0, 0)
    private var lastRateTime: TimeInterval = 0
    private var hasRates = false
    private var downHistory = RingBuffer(capacity: historyCapacity)
    private var upHistory = RingBuffer(capacity: historyCapacity)
    private var interface: NetworkInterfaceInfo?
    private var lastInterfaceRefresh: TimeInterval = 0
    private var displayNames: [String: String] = [:]

    private var wifiReader: WiFiReader?
    private var wifi: WiFiDetails?
    private var latency: LatencyMonitor?
    /// Tried once while the details are open: a socket refused now is refused a second later too.
    private var triedLatency = false
    private var processes: NetworkProcessSampler?
    private let publicAddress = PublicAddressReader()

    init() {
        takeBaseline()
    }

    func reset() {
        knownInterfaceCount = -1
        traffic.reset()
        lastRates = (0, 0)
        hasRates = false
        lastInterfaceRefresh = 0
        closeDetails()
        takeBaseline()
    }

    /// All of this stays closed unless details are on screen: the pings and the requests go out only
    /// while someone is looking at what they measure.
    func closeDetails() {
        wifiReader = nil
        wifi = nil
        latency = nil
        triedLatency = false
        processes = nil
        lastInterfaceRefresh = 0
    }

    private func takeBaseline() {
        guard let totals = readTotals() else { return }
        let now = uptimeSeconds()
        _ = traffic.rates(down: totals.down, up: totals.up, from: totals.interfaces, time: now)
        lastRateTime = now
    }

    func sample(level: SamplingLevel) -> MetricUpdate? {
        if level < .summary { closeDetails() }
        guard let totals = readTotals() else { return nil }
        let now = uptimeSeconds()
        if now - lastRateTime >= minimumSampleInterval {
            let rates = traffic.rates(down: totals.down, up: totals.up, from: totals.interfaces, time: now)
            if let rate = rates.down { lastRates.down = rate }
            if let rate = rates.up { lastRates.up = rate }
            downHistory.append(Float(lastRates.down))
            upHistory.append(Float(lastRates.up))
            lastRateTime = now
            hasRates = true
        }
        guard hasRates else { return nil }
        var snapshot = NetworkSnapshot()
        snapshot.downRate = lastRates.down
        snapshot.upRate = lastRates.up
        guard level >= .overview else { return .network(snapshot) }
        snapshot.downHistory = downHistory.values
        snapshot.upHistory = upHistory.values
        guard level >= .summary else { return .network(snapshot) }
        snapshot.totalDown = totals.down
        snapshot.totalUp = totals.up
        if now - lastInterfaceRefresh >= Self.interfaceRefreshInterval {
            // Wi-Fi is asked only when it is shown or a VPN hides it: each question goes to the Wi-Fi daemon.
            interface = readInterface {
                if wifiReader == nil { wifiReader = WiFiReader() }
                return wifiReader?.connectedInterfaceName()
            }
            if level == .detail {
                if wifiReader == nil { wifiReader = WiFiReader() }
                wifi = interface.flatMap { wifiReader?.read(interface: $0.bsdName) }
            }
            lastInterfaceRefresh = now
        }
        snapshot.interface = interface
        guard level == .detail else { return .network(snapshot) }
        if latency == nil, !triedLatency {
            triedLatency = true
            latency = LatencyMonitor()
        }
        if processes == nil { processes = NetworkProcessSampler() }
        snapshot.wifi = wifi
        snapshot.latency = latency?.current()
        snapshot.publicAddress = publicAddress.current(localAddress: interface?.address)
        snapshot.topProcesses = processes?.ranking() ?? []
        return .network(snapshot)
    }

    /// Sums 64-bit traffic counters of physical interfaces. `en*` deliberately excludes VPN tunnels,
    /// bridges, virtual machine links and AWDL, whose traffic would otherwise be counted twice.
    ///
    /// Asks for each one on its own: 7K instructions an interface, against 520K to list them all, and a Mac has
    /// around 20 interfaces of which only a few are physical. The list is only made anew when their number changes.
    private func readTotals() -> (down: UInt64, up: UInt64, interfaces: [Int32])? {
        guard let count = Self.interfaceCount() else { return nil }
        if count != knownInterfaceCount {
            knownInterfaceCount = count
            physicalInterfaces = Self.findPhysicalInterfaces(count: count)
            displayNames = [:]
        }
        var down: UInt64 = 0
        var up: UInt64 = 0
        var answered = physicalInterfaces
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, 0, IFDATA_GENERAL]
        for index in physicalInterfaces {
            mib[4] = index
            var data = ifmibdata()
            var length = MemoryLayout<ifmibdata>.size
            // An adapter that went away has no counters, and may come back at this same index.
            guard sysctl(&mib, 6, &data, &length, nil, 0) == 0 else {
                answered.removeAll { $0 == index }
                continue
            }
            down &+= data.ifmd_data.ifi_ibytes
            up &+= data.ifmd_data.ifi_obytes
        }
        return (down, up, answered)
    }

    private static func interfaceCount() -> Int32? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_SYSTEM, IFMIB_IFCOUNT]
        var count: Int32 = 0
        var length = MemoryLayout<Int32>.size
        return sysctl(&mib, 5, &count, &length, nil, 0) == 0 ? count : nil
    }

    private static func findPhysicalInterfaces(count: Int32) -> [Int32] {
        guard count > 0 else { return [] }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        return (1...count).filter { if_indextoname(UInt32($0), &name) != nil && strncmp(name, "en", 2) == 0 }
    }

    /// The interface to describe. A VPN's tunnel carries the traffic but has no signal or hardware address
    /// of its own, so with one running this looks through it to the Wi-Fi underneath, if there is any.
    private func readInterface(connectedWiFi: () -> String?) -> NetworkInterfaceInfo? {
        guard let primary = Self.primaryInterfaceName() else { return nil }
        let isTunnel = ["utun", "ipsec", "ppp"].contains { primary.hasPrefix($0) }
        let bsdName = isTunnel ? connectedWiFi() ?? primary : primary
        let addresses = Self.addresses(of: bsdName)
        return NetworkInterfaceInfo(
            bsdName: bsdName, displayName: displayName(of: bsdName), address: addresses.ipv4,
            hardwareAddress: addresses.hardware)
    }

    /// The name of an interface's kind, such as Wi-Fi or Ethernet, kept until the interfaces change: finding it lists
    /// every interface with its configuration.
    private func displayName(of bsdName: String) -> String? {
        if let known = displayNames[bsdName] { return known }
        let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let match = all.first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
        let name = match.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
        // A name the system did not give this time is asked for again next time.
        if let name { displayNames[bsdName] = name }
        return name
    }

    /// An IPv6-only network has no primary interface for IPv4.
    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Tweakly" as CFString, nil, nil) else { return nil }
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            let global = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
            if let name = global?["PrimaryInterface"] as? String { return name }
        }
        return nil
    }

    /// The interface's IPv4 address and its hardware address, from one walk through the system's list.
    private static func addresses(of interface: String) -> (ipv4: String?, hardware: String?) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return (nil, nil) }
        defer { freeifaddrs(list) }
        var ipv4: String?
        var hardware: String?
        var current = list
        while let entry = current, ipv4 == nil || hardware == nil {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, String(cString: entry.pointee.ifa_name) == interface else {
                continue
            }
            switch Int32(address.pointee.sa_family) {
            case AF_LINK where hardware == nil:
                hardware = hardwareAddress(address)
            case AF_INET where ipv4 == nil:
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    == 0
                {
                    ipv4 = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            default:
                break
            }
        }
        return (ipv4, hardware)
    }

    private static func hardwareAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let bytes = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> [UInt8] in
            let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) ?? 8
            let start = UnsafeRawPointer(link).advanced(by: dataOffset + Int(link.pointee.sdl_nlen))
            return Array(UnsafeRawBufferPointer(start: start, count: Int(link.pointee.sdl_alen)))
        }
        guard bytes.count == 6 else { return nil }
        let digits = Array("0123456789abcdef")
        return bytes.map { "\(digits[Int($0 >> 4)])\(digits[Int($0 & 15)])" }.joined(separator: ":")
    }
}
