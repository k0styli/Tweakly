import BatteryHealthCore
import Charts
import SwiftUI
import SystemMetrics

/// One device's battery: its health with how it went over time, its charge, the power going through it while
/// connected, and the rest in a sheet. A device that is not connected shows what was read last and when.
struct BatteryDevicePageView: View {
    let model: BatteryHealthModel
    let id: String
    @Environment(MainRouter.self) private var router
    @State private var showsDetails = false
    @State private var asksToForget = false

    var body: some View {
        if let device = model.archive[id] {
            page(device)
        } else {
            // Forgotten, or a page left open from before.
            ContentUnavailableView {
                Label("No Battery Data", systemImage: "battery.0percent")
            } actions: {
                Button("Show All Devices") { router.open(.batteryHealth) }
            }
        }
    }

    private func page(_ device: KnownDevice) -> some View {
        let isConnected = model.isConnected(device.id)
        let reading = device.latest
        return Form {
            Section {
                DeviceHeader(device: device, isConnected: isConnected, problem: model.unreadable[device.id]?.problem)
            }
            if device.kind.reportsCapacity {
                HealthSection(device: device)
                HistorySection(device: device)
            }
            ChargeSection(device: device, isConnected: isConnected, note: Self.note(for: device.kind))
            if isConnected, device.kind.reportsCapacity {
                PowerSection(model: model, id: id, fallback: reading)
            }
            Section {
            }
            .sectionActions {
                if device.kind != .mac {
                    // A connected device would be read again at once.
                    Button("Forget This Device…") { asksToForget = true }
                        .disabled(isConnected)
                        .help(
                            isConnected
                                ? Text("Disconnect it first: a connected device is read again.")
                                : Text("Removes its battery data and history from this Mac."))
                }
                if device.kind.reportsCapacity {
                    Button("Battery Details…") { showsDetails = true }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsDetails) {
            BatteryDetailsSheet(model: model, device: device)
        }
        .confirmationDialog(
            Text("Forget “\(BatteryText.title(of: device))”?"), isPresented: $asksToForget, titleVisibility: .visible
        ) {
            Button("Forget Device", role: .destructive) {
                router.open(.batteryHealth)
                model.forget(device.id)
            }
        } message: {
            Text("Its battery data and history are removed from this Mac. It is added again the next time it connects.")
        }
    }

    private static func note(for kind: DeviceKind) -> String? {
        switch kind {
        case .watch:
            String(localized: "The iPhone passes on only the charge of the Apple Watch paired with it.")
        case .headphones, .mouse, .keyboard, .trackpad, .gameController, .other:
            String(localized: "Accessories report only their charge, not their capacity or cycle count.")
        case .ups:
            String(localized: "A UPS reports its charge and how long it can run.")
        case .mac, .iPhone, .iPad, .iPod:
            nil
        }
    }
}

/// The device as Home shows this Mac: its picture, its name, what it is and whether it is here.
private struct DeviceHeader: View {
    private static let pictureSize: CGFloat = 96

    let device: KnownDevice
    let isConnected: Bool
    let problem: MobileDeviceReport.Problem?

    var body: some View {
        VStack(spacing: 4) {
            DevicePicture(device: device, size: Self.pictureSize)
            Text(BatteryText.title(of: device))
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            if !facts.isEmpty {
                Text(facts)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            status
                .font(.subheadline)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var facts: String {
        var parts: [String] = []
        let title = BatteryText.title(of: device)
        if device.kind != .mac, let model = DeviceArt.modelName(of: device), !BatteryText.isSame(model, title) {
            parts.append(model)
        }
        if let version = device.systemVersion {
            switch device.kind {
            case .mac: parts.append("macOS \(version)")
            case .iPhone, .iPod: parts.append("iOS \(version)")
            case .iPad: parts.append("iPadOS \(version)")
            case .watch: parts.append("watchOS \(version)")
            default: break
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var status: some View {
        if let problem, isConnected {
            Label(BatteryText.problem(problem), systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(.secondary)
        } else if isConnected {
            if let connection = BatteryText.connection(device.connection) {
                Text(connection).foregroundStyle(.secondary)
            }
        } else {
            // The owner asked that a device seen before says plainly that its data is old.
            Label {
                Text(
                    "Not Connected. Data from \(device.latest.date.formatted(date: .abbreviated, time: .shortened)).",
                    comment: "A device seen before; the date and time its battery was last read")
            } icon: {
                Image(systemName: "clock")
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// Health as coconutBattery counts it, with the bar, the system's own figure where there is one, why they differ,
/// cycles and age.
private struct HealthSection: View {
    let device: KnownDevice

    var body: some View {
        let reading = device.latest
        Section {
            if let health = reading.health {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent {
                        Text(BatteryFormat.health(health))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    } label: {
                        Text("Health", comment: "The battery's health, as coconutBattery counts it")
                        if let full = reading.fullChargeCapacity, let design = reading.designCapacity {
                            Text(
                                "\(BatteryFormat.milliampHours(full)) of \(BatteryFormat.milliampHours(design)) when new",
                                comment: "What a full charge gives now of what the battery gave when new")
                        }
                    }
                    ProgressView(value: min(health, 1))
                        .tint(health >= 0.8 ? .green : .orange)
                        .accessibilityHidden(true)
                }
            } else {
                LabeledContent("Health") { Text("Not Reported") }
            }
            if let system = reading.systemMaximumCapacity {
                LabeledContent {
                    Text(BatteryFormat.percent(system))
                } label: {
                    Text("Maximum Capacity in System Settings")
                }
            }
            if let condition = reading.condition {
                LabeledContent("Battery Condition") {
                    switch condition {
                    case .normal:
                        Text(
                            String(
                                localized: "battery.condition.normal", defaultValue: "Normal",
                                comment: "Battery condition, as System Settings says it"))
                    case .serviceRecommended: Text("Service Recommended").foregroundStyle(.orange)
                    }
                }
            }
            if let cycles = reading.cycleCount {
                LabeledContent("Cycle Count") {
                    if let design = reading.designCycleCount {
                        Text(
                            "\(BatteryFormat.number(cycles)) of \(BatteryFormat.number(design))",
                            comment: "Cycles used of those the battery is designed for")
                    } else {
                        Text(BatteryFormat.number(cycles))
                    }
                }
            }
            if let made = reading.manufactureDate {
                LabeledContent {
                    Text(made.formatted(.dateTime.day().month(.wide).year()))
                } label: {
                    Text("Manufacture Date")
                    Text(BatteryText.age(since: made, at: reading.date))
                }
            }
            if let firstUse = reading.firstUseDate {
                LabeledContent {
                    Text(firstUse.formatted(.dateTime.day().month(.wide).year()))
                } label: {
                    Text("First Use", comment: "The day the device was first set up, as iPhone Settings say it")
                }
            }
            if reading.manufactureDate == nil, reading.firstUseDate == nil, let hours = reading.lifetime?.operatingHours
            {
                LabeledContent("Battery Age") {
                    Text(BatteryText.length(hours: hours))
                }
            }
        } header: {
            Text("Battery Health")
        } footer: {
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Why the figure differs from the system's own, with this battery's numbers, so nobody thinks one of them is
    /// wrong.
    private var footnote: String? {
        let reading = device.latest
        guard let full = reading.fullChargeCapacity, let design = reading.designCapacity else { return nil }
        let given = BatteryFormat.milliampHours(full)
        let made = BatteryFormat.milliampHours(design)
        if device.kind == .mac, let nominal = reading.nominalChargeCapacity, let system = reading.systemMaximumCapacity
        {
            return String(
                localized:
                    "Health is what a full charge gives now, \(given), against \(made) when new, as coconutBattery counts it. System Settings counts what the battery holds, \(BatteryFormat.milliampHours(nominal)), and smooths it over time, so it shows \(BatteryFormat.percent(system)).",
                comment: "Footnote under a Mac's battery health")
        }
        let settings =
            device.kind == .mac
            ? String(
                localized: "System Settings work out their figure in their own way and may differ by a few percent.")
            : String(
                localized:
                    "Settings on the device work out Maximum Capacity in their own way and may differ by a few percent."
            )
        return String(
            localized:
                "Health is what a full charge gives now, \(given), against \(made) when new, as coconutBattery counts it. \(settings)",
            comment: "Footnote under a device's battery health; the last part says the device's own figure may differ")
    }
}

/// How health went, a point a day the battery was read, with Apple's 80 % line.
private struct HistorySection: View {
    let device: KnownDevice

    var body: some View {
        let points = device.history.compactMap { point in point.health.map { (date: point.date, health: $0) } }
        Section {
            if points.count >= 2 {
                HealthChart(points: points)
                if let first = points.first, let last = points.last {
                    LabeledContent {
                        Text(BatteryFormat.signedPoints(last.health - first.health))
                            .monospacedDigit()
                    } label: {
                        Text("Since \(first.date.formatted(date: .abbreviated, time: .omitted))")
                        if let cycles = cyclesSinceFirst {
                            Text(
                                "Cycles: \(BatteryFormat.number(cycles))",
                                comment: "Charge cycles since the chart's first point")
                        }
                    }
                }
            } else {
                Text("Tweakly adds a point each day it reads this battery. The chart appears from the second day.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("History")
        }
    }

    private var cyclesSinceFirst: Int? {
        guard let first = device.history.first?.cycleCount, let last = device.history.last?.cycleCount,
            last >= first
        else { return nil }
        return last - first
    }
}

private struct HealthChart: View {
    private static let height: CGFloat = 160
    /// Apple says its batteries keep 80 % for the cycles they are designed for, and recommends service below it.
    private static let serviceLine = 0.8

    let points: [(date: Date, health: Double)]

    var body: some View {
        let values = points.map(\.health)
        let lowest = min(values.min() ?? 1, Self.serviceLine)
        let highest = max(values.max() ?? 1, 1)
        // Whole steps of five, with a step of room under Apple's line.
        let floor = (lowest * 20).rounded(.down) / 20 - 0.05
        let ceiling = (highest * 20).rounded(.up) / 20
        Chart {
            ForEach(points.indices, id: \.self) { index in
                LineMark(
                    x: .value("Date", points[index].date), y: .value("Health", points[index].health)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.green)
            }
            if points.count <= 12 {
                ForEach(points.indices, id: \.self) { index in
                    PointMark(
                        x: .value("Date", points[index].date), y: .value("Health", points[index].health)
                    )
                    .symbolSize(24)
                    .foregroundStyle(.green)
                }
            }
            RuleMark(y: .value("Service", Self.serviceLine))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Color.secondary)
        }
        .chartYScale(domain: floor...ceiling)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .stride(by: 0.05)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let fraction = value.as(Double.self) {
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    }
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityLabel(Text("Health over time"))
        .accessibilityValue(
            Text(
                "From \(BatteryFormat.health(points.first?.health ?? 0)) to \(BatteryFormat.health(points.last?.health ?? 0))"
            ))
    }
}

/// The charge, what the battery is doing, and for how long.
private struct ChargeSection: View {
    let device: KnownDevice
    let isConnected: Bool
    let note: String?

    var body: some View {
        let reading = device.latest
        Section {
            if !reading.parts.isEmpty {
                ForEach(reading.parts, id: \.role) { part in
                    ChargeRow(
                        title: Text(BatteryText.partName(part.role)), percent: part.percent,
                        isCharging: part.isCharging,
                        detail: nil)
                }
            } else if let percent = reading.percent {
                // What the battery is doing goes under its charge, which is what it is about.
                let detail = [stateText(reading), reading.remainingCapacity.map { BatteryFormat.milliampHours($0) }]
                    .compactMap(\.self).joined(separator: " · ")
                ChargeRow(
                    title: Text("Charge Level"), percent: percent,
                    isCharging: reading.state == .charging,
                    detail: detail.isEmpty ? nil : detail,
                    isLowPower: reading.isLowPowerMode == true)
            }
            if !reading.parts.isEmpty, let state = stateText(reading) {
                LabeledContent("Status") { Text(state) }
            }
            if let lowPower = reading.isLowPowerMode, device.kind == .mac {
                LabeledContent("Low Power Mode") { Text(lowPower ? "On" : "Off") }
            }
        } header: {
            if isConnected {
                Text("Charge", comment: "Section with the battery's charge")
            } else {
                Text("Charge When Last Read", comment: "Section with the charge of a device that is not connected")
            }
        } footer: {
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stateText(_ reading: BatteryReading) -> String? {
        let minutes = isConnected ? reading.minutesRemaining : nil
        switch reading.state {
        case .charging:
            guard let minutes else { return String(localized: "Charging") }
            return String(localized: "Charging, \(BatteryFormat.duration(minutes: minutes)) until full")
        case .charged: return String(localized: "Charged")
        case .notCharging: return String(localized: "Not Charging")
        case .discharging:
            guard device.kind == .mac || device.kind == .ups || device.kind.reportsCapacity else { return nil }
            guard let minutes else { return String(localized: "On Battery Power") }
            return String(localized: "On Battery Power, \(BatteryFormat.duration(minutes: minutes)) left")
        case nil: return nil
        }
    }
}

private struct ChargeRow: View {
    let title: Text
    let percent: Int
    let isCharging: Bool
    let detail: String?
    var isLowPower = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack(spacing: 4) {
                    if isCharging {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                            .accessibilityLabel(Text("Charging"))
                    }
                    Text(BatteryFormat.percent(percent))
                        .monospacedDigit()
                }
            } label: {
                title
                if let detail { Text(detail) }
            }
            ProgressView(value: Double(percent), total: 100)
                .tint(isLowPower ? .yellow : percent <= 10 ? .red : .green)
                .accessibilityHidden(true)
        }
    }
}

/// Watts, the adapter and the temperature, live while the device is connected. It reads the model's live figures
/// itself, so that their changes draw these rows alone.
private struct PowerSection: View {
    let model: BatteryHealthModel
    let id: String
    let fallback: BatteryReading

    static func hasContent(_ reading: BatteryReading) -> Bool {
        reading.systemPower != nil || reading.batteryPower != nil || reading.adapter != nil
            || reading.temperature != nil
    }

    var body: some View {
        let reading = model.live[id] ?? fallback
        if Self.hasContent(reading) {
            section(reading)
        }
    }

    private func section(_ reading: BatteryReading) -> some View {
        Section {
            if let power = reading.systemPower {
                LabeledContent {
                    Text(BatteryFormat.watts(power)).monospacedDigit()
                } label: {
                    Text("Power Use", comment: "Watts the device itself uses")
                }
            }
            // On battery the Mac's use is what leaves the battery, so the flow is worth a row only on power.
            if reading.isOnPower, let power = reading.batteryPower, abs(power) >= 0.05 {
                LabeledContent {
                    Text(BatteryFormat.watts(abs(power))).monospacedDigit()
                } label: {
                    Text(power > 0 ? "Into the Battery" : "Out of the Battery")
                }
            }
            if let adapter = reading.adapter {
                LabeledContent {
                    if let input = reading.adapterPower {
                        Text(BatteryFormat.watts(input)).monospacedDigit()
                    }
                } label: {
                    Text(BatteryText.adapterTitle)
                    Text(BatteryText.adapter(adapter))
                }
            }
            if let accessories = reading.powerToAccessories, accessories >= 0.05 {
                LabeledContent {
                    Text(BatteryFormat.watts(accessories)).monospacedDigit()
                } label: {
                    Text("To Devices on Its Ports")
                }
            }
            if let temperature = reading.temperature {
                LabeledContent("Battery Temperature") {
                    Text(BatteryFormat.temperature(temperature)).monospacedDigit()
                }
            }
        } header: {
            Text("Power", comment: "Section with watts, the adapter and the temperature")
        }
    }
}

/// What a battery reports beyond the page, for those who want the numbers: capacities, electrical figures, the
/// gauge's lifetime record and the adapter.
private struct BatteryDetailsSheet: View {
    let model: BatteryHealthModel
    let device: KnownDevice

    var body: some View {
        let reading = model.isConnected(device.id) ? model.live[device.id] ?? device.latest : device.latest
        DetailsSheet(height: 560) {
            Section {
                optional("Design Capacity", reading.designCapacity.map(BatteryFormat.milliampHours))
                optional(
                    "Full Charge Capacity", reading.fullChargeCapacity.map(BatteryFormat.milliampHours),
                    detail: "What a full charge gives now. Health is counted from it.")
                optional(
                    "Nominal Capacity", reading.nominalChargeCapacity.map(BatteryFormat.milliampHours),
                    detail: "What the battery holds when full, smoothed over time.")
                optional("Remaining Capacity", reading.remainingCapacity.map(BatteryFormat.milliampHours))
            } header: {
                Text("Capacity")
            }
            Section {
                optional("Voltage", reading.voltage.map(BatteryFormat.volts))
                optional("Current", reading.current.map(BatteryFormat.amps))
                if let cells = reading.cellVoltages {
                    LabeledContent("Cells") {
                        Text(cells.map(BatteryFormat.cellVolts).formatted(.list(type: .and, width: .narrow)))
                            .monospacedDigit()
                    }
                }
                optional("Gauge", reading.gauge)
            } header: {
                Text("Electrical")
            }
            if let lifetime = reading.lifetime {
                Section {
                    optional("Highest Temperature", lifetime.highestTemperature.map(BatteryFormat.temperature))
                    optional("Lowest Temperature", lifetime.lowestTemperature.map(BatteryFormat.temperature))
                    optional("Average Temperature", lifetime.averageTemperature.map(BatteryFormat.temperature))
                    optional("Highest Charging Current", lifetime.highestChargeCurrent.map(BatteryFormat.amps))
                    optional("Highest Discharging Current", lifetime.highestDischargeCurrent.map(BatteryFormat.amps))
                    optional("Highest Voltage", lifetime.highestVoltage.map(BatteryFormat.volts))
                    optional("Lowest Voltage", lifetime.lowestVoltage.map(BatteryFormat.volts))
                    if let hours = lifetime.operatingHours {
                        LabeledContent {
                            Text(BatteryFormat.hours(hours))
                                .monospacedDigit()
                        } label: {
                            Text("Gauge Running Time")
                            Text(
                                "Counted since \(PackParser.gaugeStart(operatingHours: hours, at: reading.date).formatted(.dateTime.month(.wide).year())), when the battery’s gauge was first powered.",
                                comment: "Under the hours a battery's gauge has counted; the month and year it started")
                        }
                    }
                } header: {
                    Text("Since It Was Made")
                }
            }
            if let adapter = reading.adapter {
                Section {
                    optional("Name", adapter.name)
                    optional("Manufacturer", adapter.manufacturer)
                    optional("Rated Power", adapter.watts.map(BatteryFormat.ratedWatts))
                    optional("Voltage", adapter.voltage.map(BatteryFormat.volts))
                    optional("Current", adapter.current.map(BatteryFormat.amps))
                    if adapter.isWireless { LabeledContent("Wireless") { Text("Yes") } }
                } header: {
                    Text(BatteryText.adapterTitle)
                }
            }
            Section {
                optional("Model Identifier", device.model)
                LabeledContent("First Read") {
                    Text(device.firstSeen.formatted(date: .abbreviated, time: .omitted))
                }
                LabeledContent("Last Read") {
                    Text(reading.date.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("Device")
            }
        }
    }

    @ViewBuilder private func optional(_ title: LocalizedStringKey, _ value: String?, detail: LocalizedStringKey? = nil)
        -> some View
    {
        if let value {
            LabeledContent {
                Text(value).monospacedDigit()
            } label: {
                Text(title)
                if let detail { Text(detail) }
            }
        }
    }
}

extension BatteryText {
    /// Apple's own words for it in System Settings. The popover's "Power Adapter" names the power source there instead.
    static var adapterTitle: String {
        String(
            localized: "battery.adapter", defaultValue: "Power Adapter", comment: "The charger a device is plugged into"
        )
    }

    /// "35W USB-C Power Adapter", or what is known: "20 W, 9 V".
    static func adapter(_ adapter: PowerAdapter) -> String {
        if let name = adapter.name { return name }
        var parts: [String] = []
        if let watts = adapter.watts { parts.append(BatteryFormat.ratedWatts(watts)) }
        if let volts = adapter.voltage { parts.append(BatteryFormat.volts(volts)) }
        if adapter.isWireless { parts.append(String(localized: "Wireless")) }
        return parts.formatted(.list(type: .and, width: .narrow))
    }

    /// "3 years", "5 months": how long the gauge has been counting, in the person's language with its own grammar.
    static func length(hours: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        let years = hours / (24 * 365)
        formatter.allowedUnits = years >= 1 ? [.year] : [.month]
        let parts = years >= 1 ? DateComponents(year: years) : DateComponents(month: max(1, hours / (24 * 30)))
        return formatter.string(from: parts) ?? ""
    }

    /// "3 years ago", "5 months ago", in the person's language with its own grammar.
    static func age(since start: Date, at date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        let parts = Calendar.current.dateComponents([.year, .month], from: start, to: date)
        let whole =
            (parts.year ?? 0) >= 1
            ? DateComponents(year: -(parts.year ?? 0)) : DateComponents(month: -max(1, parts.month ?? 1))
        return formatter.localizedString(from: whole)
    }
}

extension BatteryFormat {
    /// A cell's voltage to the millivolt, so that cells drifting apart show.
    static func cellVolts(_ value: Double) -> String {
        Measurement(value: value, unit: UnitElectricPotentialDifference.volts)
            .formatted(
                .measurement(
                    width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(3))))
    }

    /// An adapter's rating, a whole number: "20 W".
    static func ratedWatts(_ watts: Int) -> String {
        String(localized: "\(watts.formatted(.number)) W")
    }

    /// "26,781 hr", grouped and in the person's language.
    static func hours(_ hours: Int) -> String {
        Measurement(value: Double(hours), unit: UnitDuration.hours)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number))
    }

    /// "−10.4 points": how health moved, in percentage points.
    static func signedPoints(_ change: Double) -> String {
        let points = (change * 100).formatted(.number.precision(.fractionLength(1)).sign(strategy: .always()))
        return String(localized: "\(points) points", comment: "A change of battery health in percentage points")
    }
}
