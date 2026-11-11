import Foundation
import SystemMetrics

extension MetricKind {
    // Looked up once, because a menu bar label asks on every update and the language only changes with a restart.
    private static let titles = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.localizedTitle(in: .main)) })
    private static let shortTitles = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, $0.localizedShortTitle(in: .main)) })
    private static let menuBarTitles = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, $0.localizedTitle(in: AppLanguage.menuBarBundle)) })
    private static let menuBarShortTitles = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, $0.localizedShortTitle(in: AppLanguage.menuBarBundle)) })

    var title: String { Self.titles[self] ?? rawValue }

    /// The short name, for finding a metric in the window.
    var shortTitle: String { Self.shortTitles[self] ?? rawValue }

    /// The name on the menu bar's item, for VoiceOver, in the language chosen for the menu bar.
    var menuBarTitle: String { Self.menuBarTitles[self] ?? rawValue }

    /// The tiny caption above a value in the menu bar, in the language chosen for it.
    var menuBarShortTitle: String { Self.menuBarShortTitles[self] ?? rawValue }

    private func localizedTitle(in bundle: Bundle) -> String {
        switch self {
        case .cpu: String(localized: "metric.cpu", defaultValue: "CPU", bundle: bundle)
        case .gpu: String(localized: "metric.gpu", defaultValue: "GPU", bundle: bundle)
        case .memory: String(localized: "metric.memory", defaultValue: "Memory", bundle: bundle)
        case .disk: String(localized: "metric.disk", defaultValue: "Disk", bundle: bundle)
        case .network: String(localized: "metric.network", defaultValue: "Network", bundle: bundle)
        case .battery: String(localized: "metric.battery", defaultValue: "Battery", bundle: bundle)
        case .fans: String(localized: "metric.fans", defaultValue: "Fans", bundle: bundle)
        }
    }

    private func localizedShortTitle(in bundle: Bundle) -> String {
        switch self {
        case .cpu: String(localized: "metric.cpu.short", defaultValue: "CPU", bundle: bundle)
        case .gpu: String(localized: "metric.gpu.short", defaultValue: "GPU", bundle: bundle)
        case .memory: String(localized: "metric.memory.short", defaultValue: "RAM", bundle: bundle)
        case .disk: String(localized: "metric.disk.short", defaultValue: "SSD", bundle: bundle)
        case .network: String(localized: "metric.network.short", defaultValue: "NET", bundle: bundle)
        case .battery: String(localized: "metric.battery.short", defaultValue: "BAT", bundle: bundle)
        case .fans: String(localized: "metric.fans.short", defaultValue: "FAN", bundle: bundle)
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .battery: "battery.100percent"
        case .fans: "fan"
        }
    }

    /// The name of this metric's page in the window, which has room for the full one.
    var pageTitle: String {
        switch self {
        case .gpu: String(localized: "metric.gpu.page", defaultValue: "Graphics Card")
        case .memory: String(localized: "metric.memory.page", defaultValue: "Memory")
        default: title
        }
    }

    /// The styles that make sense for this metric. Some would only repeat another, as a share of disk in use
    /// barely moves on a chart and network speed has no single number to put in a ring.
    var menuBarStyles: [MenuBarStyle] {
        switch self {
        case .network: [.stacked, .symbol, .filledSymbol, .ring, .column, .line, .captionBar]
        case .disk: MenuBarStyle.allCases.filter { !$0.usesHistory }
        case .battery: [.stacked, .icon, .value, .ring, .ringValue, .captionBar]
        // Four digits do not fit inside a ring.
        case .fans: [.stacked, .icon, .value, .filledSymbol, .ring, .column, .captionBar]
        default: MenuBarStyle.allCases
        }
    }

    /// Which of this metric's styles stands for `style`. Every metric can hold any style, because they all once
    /// shared one, and some draw the same here: network speed looks alike in all three text styles.
    func closestMenuBarStyle(to style: MenuBarStyle) -> MenuBarStyle {
        if menuBarStyles.contains(style) { return style }
        guard self == .network else { return .stacked }
        return switch style {
        case .ringValue: .ring
        case .signal: .column
        case .bars: .line
        default: .stacked
        }
    }

    /// The value that sets how wide this metric's item is. A percentage takes two digits, its usual state, so that
    /// neighbours keep the system's gap: one digit leaves a little room, and three reach into the free space around
    /// the item. Speeds take their widest, because the arrows at their left edge leave them nowhere to reach.
    var widthReferenceValue: MenuValue {
        switch self {
        case .network:
            let widest = CompactRate(bytesPerSecond: 888_000_000)
            return .rates(up: widest, down: widest)
        case .battery:
            return .battery(percent: 88, isCharging: false)
        case .fans:
            return .fan(rpm: 8_880, percent: 88, temperature: 88)
        default:
            return .percent(88)
        }
    }

    /// The icon inside a chart or beside a value in the menu bar.
    var menuSymbol: String {
        switch self {
        case .network: "arrow.up.arrow.down"
        default: symbol
        }
    }

    /// The solid version, which holds up better at the size of the menu bar's own icons.
    var filledMenuSymbol: String {
        switch self {
        case .network, .battery: menuSymbol
        default: menuSymbol + ".fill"
        }
    }

    /// What this metric shows in the menu bar, for the Metrics page.
    var menuBarDescription: String {
        switch self {
        case .cpu: String(localized: "Total processor load")
        case .gpu: String(localized: "Graphics processor load")
        case .memory: String(localized: "Share of memory in use")
        case .disk: String(localized: "Share of startup disk in use")
        case .network: String(localized: "Upload and download speed")
        case .battery: String(localized: "Charge level")
        case .fans: String(localized: "Average speed of the fans")
        }
    }
}
