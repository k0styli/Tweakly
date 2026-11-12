import Foundation
import SystemMetrics

/// Turns raw numbers into localized text. Menu bar formatting avoids Foundation formatters, because it
/// runs for as long as the app is open; the rest only runs while a detail view is on screen.
enum Format {
    private static let decimalSeparator = Locale.current.decimalSeparator ?? "."

    private struct RateUnits {
        let kilobytes: String
        let megabytes: String
        let gigabytes: String

        init(bundle: Bundle) {
            kilobytes = String(localized: "KB/s", bundle: bundle)
            megabytes = String(localized: "MB/s", bundle: bundle)
            gigabytes = String(localized: "GB/s", bundle: bundle)
        }
    }

    private static let rateUnits = RateUnits(bundle: .main)
    private static let menuBarRateUnits = RateUnits(bundle: AppLanguage.menuBarBundle)

    private static let fileBytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // Otherwise an empty amount reads as the word "Zero", unlike every other value in its column.
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let memoryBytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        // Otherwise an empty amount reads as the word "Zero", unlike every other value in its column.
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    // Formatter objects rather than `FormatStyle`: these run every second while details are open, and
    // the styles measurably cost more CPU and pull in more runtime metadata that is never given back.
    private static let decimalNumber: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let processPercentNumber: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let temperatureFormatter: MeasurementFormatter = {
        let formatter = MeasurementFormatter()
        formatter.unitStyle = .short
        formatter.numberFormatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let percentNumber: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static let elapsed: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// Compact form for the menu bar.
    static func percent(_ value: Int) -> String { "\(value)%" }

    /// Whole percentages, made once each, because the same few are asked for many times a second.
    private static var percentStrings = [String?](repeating: nil, count: 101)

    static func percent(_ fraction: Double) -> String {
        guard fraction >= 0, fraction <= 1 else { return percentNumber.string(from: NSNumber(value: fraction)) ?? "" }
        // The rounding the formatter uses.
        let whole = Int((fraction * 100).rounded(.toNearestOrEven))
        if let known = percentStrings[whole] { return known }
        let made = percentNumber.string(from: NSNumber(value: Double(whole) / 100)) ?? ""
        percentStrings[whole] = made
        return made
    }

    /// A figure from a sensor as a whole number. What is no number at all, or too large to be one, would stop the app if it
    /// were turned into one directly, so it reads as nothing known instead.
    private static func whole(_ value: Double) -> String {
        Int(exactly: value.rounded()).map(String.init) ?? "—"
    }

    static func rpm(_ value: Double) -> String {
        String(localized: "\(whole(value)) rpm")
    }

    /// One decimal, as Activity Monitor shows it: most busy processes sit well below one percent of a core.
    static func processLoad(_ fraction: Double) -> String {
        processPercentNumber.string(from: NSNumber(value: fraction)) ?? ""
    }

    /// Whole megahertz, without a thousands separator: `1437 MHz`.
    static func frequency(megahertz: Double) -> String {
        String(localized: "\(whole(megahertz)) MHz")
    }

    /// Whole frames per second: `60 fps`.
    static func framesPerSecond(_ value: Double) -> String {
        String(localized: "\(whole(value)) fps")
    }

    /// In the language chosen for the menu bar, which can differ from the popovers' in this same process.
    static func menuBarRate(_ rate: CompactRate, separator: String = " ") -> String {
        compact(rate, separator: separator, units: menuBarRateUnits)
    }

    private static func compact(_ rate: CompactRate, separator: String = " ", units: RateUnits) -> String {
        let whole = rate.tenths / 10
        let number = rate.showsDecimal ? "\(whole)\(decimalSeparator)\(rate.tenths % 10)" : "\(whole)"
        let unit =
            switch rate.unit {
            case .kilobytes: units.kilobytes
            case .megabytes: units.megabytes
            case .gigabytes: units.gigabytes
            }
        return number + separator + unit
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        compact(CompactRate(bytesPerSecond: bytesPerSecond), units: rateUnits)
    }

    /// Storage sizes, in decimal units as Finder shows them.
    static func fileSize(_ bytes: UInt64) -> String {
        fileBytes.string(fromByteCount: Int64(clamping: bytes))
    }

    /// Memory sizes, in binary units as Activity Monitor shows them.
    static func memorySize(_ bytes: UInt64) -> String {
        memoryBytes.string(fromByteCount: Int64(clamping: bytes))
    }

    static func hoursAndMinutes(_ minutes: Int) -> String {
        let rest = minutes % 60
        return "\(minutes / 60):\(rest < 10 ? "0" : "")\(rest)"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        elapsed.string(from: seconds) ?? ""
    }

    static func decimal(_ value: Double, digits: Int = 2) -> String {
        decimalNumber.minimumFractionDigits = digits
        decimalNumber.maximumFractionDigits = digits
        return decimalNumber.string(from: NSNumber(value: value)) ?? ""
    }

    static func temperature(celsius: Double) -> String {
        temperatureFormatter.string(from: Measurement(value: celsius, unit: UnitTemperature.celsius))
    }

    /// The unit the region chose in Language & Region, which `temperature(celsius:)` follows too.
    private static let regionTemperatureUnit = UnitTemperature(forLocale: .current)

    /// Whole degrees in the region's unit, for where only a number and a degree sign fit: the menu bar and a chart's
    /// axis. In Celsius there, beside Fahrenheit in the popovers, 52° and 126° would be the same heat.
    static func degrees(celsius: Double) -> Int {
        let value = Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: regionTemperatureUnit)
            .value
        return value.isFinite ? Int(value.rounded()) : 0
    }

    static func watts(_ value: Double) -> String {
        // Small draws would otherwise round down to a reading of nothing.
        String(localized: "\(decimal(value, digits: value < 1 ? 2 : 1)) W")
    }

    /// Milliseconds, with a decimal only while it still means something: `9,6 ms`, `124 ms`.
    static func milliseconds(_ value: Double) -> String {
        String(localized: "\(decimal(value, digits: value < 100 ? 1 : 0)) ms")
    }

    /// Decibels against a milliwatt, with a proper minus sign: `−43 dBm`.
    static func decibels(_ value: Int) -> String {
        String(localized: "\(signed(value)) dBm")
    }

    /// A whole number with a proper minus sign; its magnitude, which `Int.min` has too, never traps.
    private static func signed(_ value: Int) -> String {
        value < 0 ? "\u{2212}\(value.magnitude)" : String(value)
    }

    static func megabitsPerSecond(_ value: Double) -> String {
        String(localized: "\(whole(value)) Mbps")
    }

    /// The flag emoji for a two-letter country code, which is two regional indicator symbols.
    static func flag(countryCode: String) -> String {
        let scalars = countryCode.uppercased().unicodeScalars.compactMap { Unicode.Scalar(0x1F1A5 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A rated power, which is always a whole number: `35 W`.
    static func wholeWatts(_ value: Int) -> String {
        String(localized: "\(String(value)) W")
    }

    /// Whole milliamps with a proper minus sign, and no thousands separator so the column stays narrow.
    static func milliamps(_ value: Int) -> String {
        String(localized: "\(signed(value)) mA")
    }

    /// Whole milliamp hours, with no thousands separator: `4117 mAh`.
    static func milliampHours(_ value: Int) -> String {
        String(localized: "\(String(value)) mAh")
    }

    static func volts(_ value: Double) -> String {
        String(localized: "\(decimal(value, digits: 2)) V")
    }
}
