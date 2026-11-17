import AppKit
import BatteryHealthCore
import SystemMetrics
import UniformTypeIdentifiers

/// Each device's picture and model name as Finder shows them. macOS declares a type for every model it knows, iPhones by
/// their model code ("iPhone16,1") and AirPods and Beats by Apple's Bluetooth numbers ("76:8212"), with the picture and
/// the name in the person's language. A model newer than this Mac's system, and accessories it has no picture of, get
/// an SF Symbol.
enum DeviceArt {
    private static let modelCode = UTTagClass(rawValue: "com.apple.device-model-code")
    private static let bluetoothProduct = UTTagClass(rawValue: "public.bluetooth-vendor-product-id")
    /// Pictures are drawn by Launch Services and asked for again with every redraw, so each is made once.
    private static var pictures: [String: NSImage] = [:]

    static func type(of device: KnownDevice) -> UTType? {
        if let model = device.model, let type = UTType(tag: model, tagClass: modelCode, conformingTo: nil),
            !type.isDynamic
        {
            return type
        }
        if let vendor = device.vendorID, let product = device.productID,
            let type = UTType(tag: "\(vendor):\(product)", tagClass: bluetoothProduct, conformingTo: nil),
            !type.isDynamic
        {
            return type
        }
        return nil
    }

    /// "iPhone 15 Pro", "AirPods Pro (2nd generation)"; nil where macOS does not know the model.
    static func modelName(of device: KnownDevice) -> String? {
        if device.kind == .mac { return SystemInfo.current.productName }
        return type(of: device)?.localizedDescription
    }

    static func picture(of device: KnownDevice) -> NSImage? {
        if device.kind == .mac { return NSImage(named: NSImage.computerName) }
        guard let type = type(of: device) else { return nil }
        if let known = pictures[type.identifier] { return known }
        let picture = NSWorkspace.shared.icon(for: type)
        pictures[type.identifier] = picture
        return picture
    }

    static func symbol(of device: KnownDevice) -> String {
        switch device.kind {
        case .mac: SystemInfo.hasBattery ? "laptopcomputer" : "desktopcomputer"
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .iPod: "ipodtouch"
        case .watch: "applewatch"
        case .headphones:
            device.name.localizedCaseInsensitiveContains("max")
                ? "airpodsmax" : device.name.localizedCaseInsensitiveContains("pro") ? "airpods.pro" : "headphones"
        case .speaker: "hifispeaker"
        case .mouse: "magicmouse"
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gameController: "gamecontroller"
        case .ups: "bolt.batteryblock"
        case .other: "battery.100percent"
        }
    }
}
