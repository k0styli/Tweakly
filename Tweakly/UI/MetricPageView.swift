import AppKit
import SwiftUI
import SystemMetrics

/// One metric's page: whether it shows in the menu bar, how it looks there and how often it updates.
struct MetricPageView: View {
    let kind: MetricKind
    @Bindable var settings: AppSettings
    /// Goes to another page of the window.
    let open: (MainPage) -> Void
    let isWindowVisible: Bool

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: kind.symbol, title: Text("Show in Menu Bar"), detail: Text(kind.menuBarDescription),
                    isOn: isShown
                )
                .disabled(isInSimpleView)
                if isInSimpleView {
                    LabeledContent("This metric is in Simple View, so it has no icon of its own.") {
                        Button("Open Simple View") { open(.simpleView) }
                    }
                }
            }
            if kind == .fans {
                FanControlSections(settings: settings, isWindowVisible: isWindowVisible)
            }
            Section("Style") {
                StylePicker(kind: kind, settings: settings)
                if showsAlignment {
                    LabeledContent("Name alignment") {
                        Picker("Name alignment", selection: appearance.alignment) {
                            ForEach(CaptionAlignment.allCases) { alignment in
                                Text(alignment.title).tag(alignment)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                    }
                }
                if kind == .fans {
                    Picker("Show in Menu Bar", selection: $settings.fansShowTemperature) {
                        Text("Speed").tag(false)
                        Text("Temperature").tag(true)
                    }
                }
                if showsBatteryColor {
                    Toggle("Color the battery while charging", isOn: $settings.colorsBatteryWhileCharging)
                }
            }
            .disabled(!showsOwnIcon)
            updatesSection
                .disabled(!showsOwnIcon)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var updatesSection: some View {
        Section {
            switch kind {
            case .disk:
                LabeledContent("Updates", value: String(localized: "Every 2 minutes"))
            case .battery:
                LabeledContent("Updates", value: String(localized: "When the charge changes"))
            default:
                Picker(selection: appearance.interval) {
                    ForEach(UpdateInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                } label: {
                    Text("Update every")
                    Text("Less frequent updates use less energy. Low Power Mode slows them down further.")
                }
            }
        }
    }

    private var isInSimpleView: Bool { settings.simpleViewEnabled && settings.simpleViewMetrics.contains(kind) }

    private var showsOwnIcon: Bool { isShown.wrappedValue && !isInSimpleView }

    private var usesOwnBatteryStyle: Bool { kind == .battery && settings.batteryStyle != .sameAsOthers }

    /// Network speed has no name above it in its text style, so there is nothing to align.
    private var showsAlignment: Bool {
        let style = kind.closestMenuBarStyle(to: settings.appearance(of: kind).style)
        return !usesOwnBatteryStyle && style.usesCaption && !(kind == .network && style == .stacked)
    }

    private var showsBatteryColor: Bool { usesOwnBatteryStyle }

    private var isShown: Binding<Bool> {
        Binding(
            get: { settings.enabledMetrics.contains(kind) },
            set: { isOn in
                if isOn {
                    settings.enabledMetrics.insert(kind)
                } else {
                    settings.enabledMetrics.remove(kind)
                }
            }
        )
    }

    private var appearance: Binding<MetricAppearance> {
        Binding(
            get: { settings.appearance(of: kind) },
            set: { settings.appearances[kind] = $0 }
        )
    }
}

/// Shows each style with a real rendering, in the manner of the Appearance choice in System Settings.
private struct StylePicker: View {
    private enum Choice: Hashable, Identifiable {
        case battery(BatteryBarStyle)
        case general(MenuBarStyle)

        var id: String {
            switch self {
            case .battery(let style): "battery.\(style.rawValue)"
            case .general(let style): style.rawValue
            }
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 108), spacing: 10, alignment: .top)]

    let kind: MetricKind
    @Bindable var settings: AppSettings

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 12) {
            ForEach(choices) { choice in
                LookChoice(title: title(of: choice), isSelected: choice == selected) {
                    select(choice)
                } preview: {
                    preview(choice)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var choices: [Choice] {
        let general = kind.menuBarStyles.map(Choice.general)
        return kind == .battery ? [.battery(.glyph), .battery(.number), .battery(.side)] + general : general
    }

    private var selected: Choice {
        if kind == .battery && settings.batteryStyle != .sameAsOthers { return .battery(settings.batteryStyle) }
        return .general(kind.closestMenuBarStyle(to: settings.appearance(of: kind).style))
    }

    private func title(of choice: Choice) -> String {
        switch choice {
        case .battery(let style): style.title
        // There is no name above network speed in this style, only the two values.
        case .general(.stacked) where kind == .network: String(localized: "Speed")
        case .general(let style): style.title
        }
    }

    private func select(_ choice: Choice) {
        switch choice {
        case .battery(let style):
            settings.batteryStyle = style
        case .general(let style):
            if kind == .battery { settings.batteryStyle = .sameAsOthers }
            settings.appearances[kind]?.style = style
        }
    }

    private func preview(_ choice: Choice) -> some View {
        StatusLabelImage(content: StatusLabelSample.content(kind: kind, options: options(for: choice)))
    }

    private func options(for choice: Choice) -> StatusLabelOptions {
        let alignment = settings.appearance(of: kind).alignment
        switch choice {
        case .battery(let style):
            return StatusLabelOptions(style: .stacked, alignment: alignment, batteryStyle: style)
        case .general(let style):
            return StatusLabelOptions(
                style: style, alignment: alignment, batteryStyle: .sameAsOthers,
                fanShowsTemperature: settings.fansShowTemperature)
        }
    }
}

/// A menu bar label as an image, drawn by the same code as the real one and so always matching it.
struct StatusLabelImage: View {
    private static let height: CGFloat = 22

    let content: StatusLabelContent
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let size = CGSize(width: StatusLabelRenderer.width(of: content), height: Self.height)
        let bitmaps = StatusLabelRenderer.render(content, size: size, scale: displayScale, accentColor: accentColor)
        ZStack {
            if let mask = bitmaps.mask {
                Image(decorative: mask, scale: displayScale)
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
            }
            if let colored = bitmaps.colored {
                Image(decorative: colored, scale: displayScale)
            }
        }
    }

    private var accentColor: CGColor? {
        guard let accent = content.accent,
            let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        else { return nil }
        var color: CGColor?
        appearance.performAsCurrentDrawingAppearance { color = accent.color.cgColor }
        return color
    }
}

extension MenuBarStyle {
    var title: String {
        switch self {
        case .stacked: String(localized: "Name and value")
        case .icon: String(localized: "Icon and value")
        case .value: String(localized: "Value only")
        case .symbol: String(localized: "Icon only")
        case .filledSymbol: String(localized: "Filling icon")
        case .ring: String(localized: "Ring")
        case .ringValue: String(localized: "Ring with number")
        case .column: String(localized: "Icon and column")
        case .signal: String(localized: "Icon and signal bars")
        case .line: String(localized: "Icon and line chart")
        case .bars: String(localized: "Icon and bar chart")
        case .captionBar: String(localized: "Name and bar")
        }
    }
}

extension CaptionAlignment {
    var title: String {
        switch self {
        case .left: String(localized: "Left")
        case .center: String(localized: "Center")
        case .right: String(localized: "Right")
        }
    }
}

extension BatteryBarStyle {
    var title: String {
        switch self {
        case .glyph: String(localized: "Icon")
        case .number: String(localized: "Icon with number")
        case .side: String(localized: "Number beside icon")
        case .sameAsOthers: String(localized: "Name and value")
        }
    }
}

extension UpdateInterval {
    var title: String {
        switch self {
        case .fast: String(localized: "1 second")
        case .normal: String(localized: "2 seconds")
        case .relaxed: String(localized: "5 seconds")
        }
    }
}
