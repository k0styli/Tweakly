import CoreWLAN

/// The quality of the Wi-Fi link. CoreWLAN is public and gives all of this without permission. Only the
/// network's name needs Location access, so it is not read here. Checked on macOS 27.2.
final class WiFiReader {
    private let client = CWWiFiClient()

    /// The Wi-Fi interface, if it is connected to a network.
    func connectedInterfaceName() -> String? {
        guard let wifi = client.interface(), wifi.powerOn(), wifi.rssiValue() != 0 else { return nil }
        return wifi.interfaceName
    }

    /// Nil if that interface is not Wi-Fi, or is not connected.
    func read(interface name: String) -> WiFiDetails? {
        guard let wifi = client.interface(withName: name), wifi.powerOn(), wifi.interfaceMode() != .none else {
            return nil
        }
        let signal = wifi.rssiValue()
        // A radio that is on but not associated reports no signal at all.
        guard signal != 0 else { return nil }
        let channel = wifi.wlanChannel()
        return WiFiDetails(
            signal: signal,
            transmitRate: wifi.transmitRate(),
            channel: channel?.channelNumber,
            band: channel.flatMap { Self.band($0.channelBand) },
            generation: Self.generation(wifi.activePHYMode())
        )
    }

    private static func band(_ band: CWChannelBand) -> WiFiDetails.Band? {
        switch band {
        case .band2GHz: .twoPointFour
        case .band5GHz: .five
        case .band6GHz: .six
        default: nil
        }
    }

    /// The number in the "Wi-Fi 6" naming, for the standards that have one.
    private static func generation(_ mode: CWPHYMode) -> Int? {
        switch mode {
        case .mode11n: 4
        case .mode11ac: 5
        case .mode11ax: 6
        default: mode.rawValue == 7 ? 7 : nil
        }
    }
}
