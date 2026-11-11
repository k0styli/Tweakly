import AppKit
import FanControlCore
import SystemMetrics

/// The popover's way to the settings, so that it holds none of them.
struct FanQuickActions {
    /// Nil when what is set is no profile, such as settings someone changed and did not save.
    let current: () -> FanProfileChoice?
    let choose: (FanProfileChoice) -> Void
    let openWindow: () -> Void
    let problem: () -> String?
}

extension FanProfile {
    var title: String {
        switch self {
        case .system: String(localized: "fan.profile.system", defaultValue: "System")
        case .quiet: String(localized: "fan.profile.quiet", defaultValue: "Quiet")
        case .balanced: String(localized: "fan.profile.balanced", defaultValue: "Balanced")
        case .performance: String(localized: "fan.profile.performance", defaultValue: "Performance")
        case .maximum: String(localized: "fan.profile.maximum", defaultValue: "Maximum")
        }
    }

    /// For the popover's row of all five, where the whole words do not fit.
    var shortTitle: String {
        switch self {
        case .performance: String(localized: "fan.profile.performance.short", defaultValue: "Power")
        case .maximum: String(localized: "fan.profile.maximum.short", defaultValue: "Max")
        default: title
        }
    }
}

extension FanSettings {
    /// Every profile by name, the app's first.
    var allProfiles: [(choice: FanProfileChoice, title: String)] {
        FanProfile.allCases.map { (.builtIn($0), $0.title) } + savedProfiles.map { (.saved($0.id), $0.name) }
    }

    func title(of choice: FanProfileChoice) -> String? {
        allProfiles.first { $0.choice == choice }?.title
    }
}

extension FanSnapshot {
    /// The speed of the fans in a few characters, or that they stand still, which is news on a Mac that can.
    var speedText: String {
        averageRPM < 1 ? Self.stoppedText : Format.rpm((averageRPM / 10).rounded() * 10)
    }

    /// Apart from one fan's, because in Russian one fan and several take different endings.
    static var stoppedText: String {
        String(localized: "fans.stopped", defaultValue: "Stopped")
    }

    static func fanName(_ index: Int) -> String {
        String(localized: "Fan \(String(index + 1))")
    }
}

/// The fans' popover: how fast each one goes against its limits, what they follow, and a quick choice of what they do.
final class FanDetailView: NSStackView, MetricDetailContent {
    private let header = DetailHeaderView(title: MetricKind.fans.title, widestValue: Format.rpm(8_880))
    private let graph = SparklineView(maximum: 1)
    private let fansColumn = NSStackView.detailColumn(spacing: 8, [])
    private let cpuRow = DetailRow(String(localized: "Processor, hottest"))
    private let gpuRow = DetailRow(String(localized: "Graphics, hottest"))
    private let actions: FanQuickActions?
    private lazy var choices = NSSegmentedControl(
        labels: FanProfile.allCases.map(\.shortTitle), trackingMode: .selectOne, target: self, action: #selector(choose)
    )
    private let note = NSTextField.detailLabel("", color: .secondaryLabelColor)
    private lazy var settingsButton = NSButton(
        title: String(localized: "Fan Settings…"), target: self, action: #selector(openSettings))
    private var fanRows: [(row: DetailRow, bar: SegmentBarView)] = []

    init(actions: FanQuickActions?) {
        self.actions = actions
        super.init(frame: .zero)
        setUpAsDetailColumn(spacing: DetailLayout.sectionSpacing)

        addFullWidth(header)
        addFullWidth(graph)
        addFullWidth(fansColumn)
        addFullWidth(NSStackView.detailColumn([cpuRow, gpuRow]))
        if actions != nil {
            choices.segmentDistribution = .fillProportionally
            choices.controlSize = .regular
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 0
            settingsButton.bezelStyle = .accessoryBar
            settingsButton.controlSize = .small
            addFullWidth(
                NSStackView.detailColumn(
                    spacing: 6, [detailSectionTitle(String(localized: "Control")), choices, note, settingsButton]))
        }
        refreshControl()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(_ update: MetricUpdate) {
        guard case .fans(let fans) = update else { return }
        let temperatures = fans.temperatures
        header.update(subtitle: FanModeText.short(), value: fans.speedText)
        header.setSide(
            temperatures.hottest.map(Format.temperature(celsius:)), color: chipTemperatureColor(temperatures.hottest))
        graph.update([.init(values: fans.history, color: .controlAccentColor)])
        showFans(fans.fans)
        cpuRow.set(temperatures.hottestCPU.map(Format.temperature(celsius:)))
        gpuRow.set(temperatures.hottestGPU.map(Format.temperature(celsius:)))
        refreshControl()
    }

    private func showFans(_ fans: [FanReading]) {
        while fanRows.count < fans.count {
            let row = DetailRow(FanSnapshot.fanName(fanRows.count))
            let bar = SegmentBarView(height: 6)
            fanRows.append((row, bar))
            fansColumn.addFullWidth(NSStackView.detailColumn(spacing: 4, [row, bar]))
        }
        for (fan, views) in zip(fans, fanRows) {
            // A fan overshoots its limit by a few rpm as it settles, which reads as a mistake.
            let speed = Int(min(fan.actual, fan.maximum).rounded())
            views.row.set(fan.actual < 1 ? String(localized: "Stopped") : "\(speed) / \(Format.rpm(fan.maximum))")
            views.bar.update([
                .init(fraction: fan.maximum > 0 ? fan.actual / fan.maximum : 0, color: .controlAccentColor)
            ])
        }
    }

    private func refreshControl() {
        guard let actions else { return }
        var selected = -1
        if case .builtIn(let profile)? = actions.current(), let index = FanProfile.allCases.firstIndex(of: profile) {
            selected = index
        }
        if choices.selectedSegment != selected { choices.selectedSegment = selected }
        let canControl = FanHelperClient.isInstalled
        choices.isEnabled = canControl
        let text =
            canControl
            ? actions.problem() ?? (selected < 0 ? String(localized: "Set in Tweakly's settings.") : nil)
            : String(localized: "Changing the speed of the fans takes a helper, which is installed in the settings.")
        note.setIfChanged(text ?? "")
        note.isHidden = text == nil
    }

    @objc private func choose() {
        guard FanProfile.allCases.indices.contains(choices.selectedSegment) else { return }
        actions?.choose(.builtIn(FanProfile.allCases[choices.selectedSegment]))
        refreshControl()
    }

    @objc private func openSettings() {
        actions?.openWindow()
    }
}

/// What the fans are set to do, in a few words, for the headers of popovers. Preferences are compared before anything is
/// decoded, because a popover asks every second.
enum FanModeText {
    private static var lastData: Data?
    private static var lastOnBattery = false
    private static var hasBatteryPlan = false
    private static var lastLong = ""
    private static var lastShort = ""

    static func current() -> String {
        refresh()
        return lastLong
    }

    /// A word or two, for a narrow column.
    static func short() -> String {
        refresh()
        return lastShort
    }

    private static func refresh() {
        let data = AppSettings.savedFanSettingsData
        let onBattery = hasBatteryPlan && FanDriver.isOnBattery
        if lastData == data, lastOnBattery == onBattery, !lastLong.isEmpty { return }
        lastData = data
        let settings = data.flatMap { try? JSONDecoder().decode(FanSettings.self, from: $0) } ?? FanSettings()
        hasBatteryPlan = settings.battery != nil
        lastOnBattery = hasBatteryPlan && FanDriver.isOnBattery
        let plan = settings.plan(onBattery: lastOnBattery)
        let choice = settings.profile(of: plan)
        lastShort = choice.flatMap(settings.title(of:)) ?? unnamed(plan)
        lastLong =
            choice == .builtIn(.system) ? String(localized: "Run by the system") : lastShort
    }

    /// Settings that are no profile, by what they do: "own settings" would say nothing, and does not fit the header.
    private static func unnamed(_ plan: FanPlan) -> String {
        guard plan.isLinked else { return String(localized: "fan.mode.separate", defaultValue: "Separate") }
        switch plan.shared.mode {
        case .system: return FanMode.system.title
        case .fixed: return Format.percent(plan.shared.fixedPercent / 100)
        case .curve: return FanMode.curve.title
        }
    }
}
