import CryptoKit
import Foundation

/// Names a device in the archive without keeping its own identifier: a UDID or a Bluetooth address is personal, and the
/// archive only needs to tell one device from another.
public enum DeviceIdentity {
    public static let thisMac = "mac"

    public static func id(kind: String, raw: String) -> String {
        let digest = SHA256.hash(data: Data(("tweakly.battery." + raw).utf8))
        return kind + ":" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
