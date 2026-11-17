import BatteryHealthCore
import SwiftUI
import SystemMetrics

/// Battery Health: this Mac, the devices connected now and those seen before, each a row that opens its own page, as
/// devices are listed in Bluetooth in System Settings. Health is counted as coconutBattery counts it.
struct BatteryHealthPageView: View {
    let model: BatteryHealthModel
    @Environment(MainRouter.self) private var router

    var body: some View {
        let others = model.others
        let unknown = model.unreadable.filter { model.archive[$0.key] == nil }.sorted { $0.key < $1.key }
        Form {
            Section {
                FeatureLabel(
                    symbol: MainPage.batteryHealth.symbol, title: Text("Battery Health"),
                    detail: Text("How worn the batteries of this Mac and your devices are, and how they charge."))
            }
            Section {
                if let mac = model.mac {
                    row(mac)
                } else if model.macHasNoBattery {
                    MacWithoutBatteryRow(power: model.macPowerWithoutBattery)
                }
            } header: {
                Text("This Mac")
            }
            if !others.connected.isEmpty || !unknown.isEmpty {
                Section {
                    ForEach(others.connected) { row($0) }
                    ForEach(unknown, id: \.key) { UnreadableDeviceRow(state: $0.value) }
                } header: {
                    Text("Connected")
                }
            }
            if !others.away.isEmpty {
                Section {
                    ForEach(others.away) { row($0) }
                } header: {
                    Text("Not Connected")
                }
            }
            if others.connected.isEmpty, others.away.isEmpty, unknown.isEmpty {
                HowToAddDevices(readsMobileDevices: model.readsMobileDevices)
            } else {
                Section {
                } footer: {
                    Text(
                        "iPhone and iPad appear by cable or on the same Wi‑Fi, Apple Watch through its iPhone, AirPods and accessories while connected by Bluetooth."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ device: KnownDevice) -> some View {
        DeviceRow(
            device: device, isConnected: model.isConnected(device.id),
            problem: model.unreadable[device.id]?.problem
        ) {
            router.open(.batteryDevice(device.id))
        }
    }
}

/// A device in the list: its picture, name, model and state, and its health or charge at the end.
private struct DeviceRow: View {
    static let pictureSize: CGFloat = 32

    let device: KnownDevice
    let isConnected: Bool
    let problem: MobileDeviceReport.Problem?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                DevicePicture(device: device, size: Self.pictureSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(BatteryText.title(of: device))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                trailing
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let model = DeviceArt.modelName(of: device), !BatteryText.isSame(model, BatteryText.title(of: device)),
            device.kind != .mac
        {
            parts.append(model)
        }
        if let problem, isConnected {
            parts.append(BatteryText.problem(problem))
        } else if isConnected {
            parts.append(BatteryText.chargeSummary(device.latest))
        } else {
            parts.append(
                String(
                    localized: "Not Connected, \(BatteryText.relative(device.latest.date))",
                    comment: "A device seen before: when its data was read, such as “3 days ago”"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        if let health = device.latest.health {
            VStack(alignment: .trailing, spacing: 1) {
                Text(BatteryFormat.health(health))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text("Health", comment: "Under the battery's health in percent in a device's row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let percent = device.latest.lowestPercent {
            ChargeLabel(percent: percent, isCharging: device.latest.state == .charging)
        }
    }
}

/// A charge with the battery symbol the menu bar would show for it.
struct ChargeLabel: View {
    let percent: Int
    var isCharging = false

    var body: some View {
        HStack(spacing: 4) {
            Text(BatteryFormat.percent(percent))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: BatteryFormat.symbol(percent: percent, isCharging: isCharging))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

/// A device's own picture as Finder draws it, or its SF Symbol.
struct DevicePicture: View {
    let device: KnownDevice
    let size: CGFloat

    var body: some View {
        Group {
            if let picture = DeviceArt.picture(of: device) {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: DeviceArt.symbol(of: device))
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A desktop Mac: no battery to wear, only the power it uses.
private struct MacWithoutBatteryRow: View {
    let power: Double?

    var body: some View {
        HStack(spacing: 10) {
            if let picture = NSImage(named: NSImage.computerName) {
                Image(nsImage: picture)
                    .resizable()
                    .scaledToFit()
                    .frame(width: DeviceRow.pictureSize, height: DeviceRow.pictureSize)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(SystemInfo.current.productName ?? "Mac")
                Text("This Mac has no battery and runs from power.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let power {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(BatteryFormat.watts(power))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                    Text("Power Use", comment: "Under the watts a Mac uses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// An iPhone or iPad on the cable that could not be read and was never read before, so nothing is known of it.
private struct UnreadableDeviceRow: View {
    let state: BatteryHealthModel.Unreadable

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: DeviceRow.pictureSize * 0.6))
                .foregroundStyle(.secondary)
                .frame(width: DeviceRow.pictureSize, height: DeviceRow.pictureSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("iPhone or iPad", comment: "A connected device that could not be read yet")
                Text(BatteryText.problem(state.problem))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown until the first device other than this Mac is read: where each kind of device comes from.
private struct HowToAddDevices: View {
    let readsMobileDevices: Bool

    var body: some View {
        Section {
            hint(
                symbol: "iphone", title: Text("iPhone and iPad"),
                detail: readsMobileDevices
                    ? Text(
                        "Connect it with a cable. Over Wi‑Fi it appears when “Show this iPhone when on Wi‑Fi” is on in Finder."
                    )
                    : Text("This version of macOS does not let Tweakly read them."))
            hint(
                symbol: "applewatch", title: Text("Apple Watch"),
                detail: Text("Appears with the iPhone it is paired with, while that iPhone is connected."))
            hint(
                symbol: "airpods.pro", title: Text("AirPods and Accessories"),
                detail: Text("Appear while they are connected to this Mac by Bluetooth."))
        } header: {
            Text("Other Devices")
        }
    }

    private func hint(symbol: String, title: Text, detail: Text) -> some View {
        Label {
            title
            detail
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: LinkRow<EmptyView>.symbolWidth)
                .accessibilityHidden(true)
        }
    }
}

/// Words shared by the list and a device's page.
enum BatteryText {
    /// The name its owner gave it, or the model's.
    static func title(of device: KnownDevice) -> String {
        if device.kind == .mac { return DeviceArt.modelName(of: device) ?? device.name }
        if !device.name.isEmpty { return device.name }
        return DeviceArt.modelName(of: device) ?? String(localized: "Device", comment: "A device with no name")
    }

    /// Names that differ only in case or in the kind of space, as the system's model names can.
    static func isSame(_ first: String, _ second: String) -> Bool {
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
        }
        return plain(first).localizedCaseInsensitiveCompare(plain(second)) == .orderedSame
    }

    static func connection(_ connection: Connection) -> String? {
        switch connection {
        case .builtIn: nil
        case .usb: String(localized: "Connected by cable")
        case .wifi: String(localized: "Connected over Wi‑Fi")
        case .bluetooth: String(localized: "Connected by Bluetooth")
        case .pairedPhone: String(localized: "Through its iPhone")
        }
    }

    static func state(_ state: ChargeState?) -> String? {
        switch state {
        case .charging: String(localized: "Charging")
        case .charged: String(localized: "Charged")
        case .notCharging: String(localized: "Not Charging")
        case .discharging, nil: nil
        }
    }

    /// "Charging, 72 %", or the charge alone; AirPods give each part.
    static func chargeSummary(_ reading: BatteryReading) -> String {
        if !reading.parts.isEmpty {
            return reading.parts.map { part in
                "\(partName(part.role)) \(BatteryFormat.percent(part.percent))"
            }.formatted(.list(type: .and, width: .narrow))
        }
        guard let percent = reading.percent else { return state(reading.state) ?? "" }
        guard let word = state(reading.state) else {
            return String(
                localized: "Charge \(BatteryFormat.percent(percent))",
                comment: "A battery's charge, such as “Charge 84 %”")
        }
        return String(
            localized: "\(word), \(BatteryFormat.percent(percent))",
            comment: "The state of a battery and its charge, such as “Charging, 72 %”")
    }

    static func partName(_ role: BatteryPart.Role) -> String {
        switch role {
        case .left: String(localized: "battery.part.left", defaultValue: "Left", comment: "The left AirPod")
        case .right: String(localized: "battery.part.right", defaultValue: "Right", comment: "The right AirPod")
        case .chargingCase:
            String(localized: "battery.part.case", defaultValue: "Case", comment: "The AirPods charging case")
        case .single: String(localized: "battery.part.single", defaultValue: "Battery", comment: "A single battery")
        }
    }

    static func problem(_ problem: MobileDeviceReport.Problem) -> String {
        switch problem {
        case .notTrusted: String(localized: "Unlock it and tap Trust to let this Mac read it.")
        case .locked: String(localized: "Unlock it to read its battery.")
        case .unreadable: String(localized: "It did not answer. Connect it again to try once more.")
        }
    }

    /// "3 days ago", "1 minute ago", "now".
    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return String(localized: "just now") }
        return date.formatted(.relative(presentation: .named))
    }
}

/// Figures as the system writes them in the person's language.
enum BatteryFormat {
    static func percent(_ percent: Int) -> String {
        (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    /// One decimal, as coconutBattery shows it: 89.1 %.
    static func health(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    static func milliampHours(_ value: Int) -> String {
        String(localized: "\(value.formatted(.number)) mAh")
    }

    static func watts(_ value: Double) -> String {
        String(localized: "\(value.formatted(.number.precision(.fractionLength(1)))) W")
    }

    static func volts(_ value: Double) -> String {
        Measurement(value: value, unit: UnitElectricPotentialDifference.volts)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2))))
    }

    static func amps(_ value: Double) -> String {
        Measurement(value: value, unit: UnitElectricCurrent.amperes)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(2))))
    }

    static func temperature(_ celsius: Double) -> String {
        Measurement(value: celsius, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))))
    }

    static func number(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func duration(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static func symbol(percent: Int, isCharging: Bool) -> String {
        if isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
