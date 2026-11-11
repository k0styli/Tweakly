import AppKit
import Combine
import FanControlCore
import SwiftUI
import SystemMetrics
import TipKit

/// The first page of the window: this Mac and how it is doing, the figures behind that, what each tweak is up to and
/// what is working the hardest. Laid out as About, Software Update and Privacy & Security in System Settings.
///
/// Values arrive every second, but most of what they say does not change that often. Each part of the page therefore
/// is a view of its own that reads only the values it shows, and `Equatable` views below them keep an unchanged row
/// from being worked out and laid out again.
struct HomeView: View {
    let data: StatsLiveData
    let settings: AppSettings
    let isWindowVisible: Bool
    let open: (MainPage) -> Void
    /// Read when the page appears and when the window comes back into view. The tweaks' own pages watch them while
    /// someone waits for one; here a missing one only has to be noticed. Not in the initial value, which SwiftUI works
    /// out again each time the window's content is rebuilt, and asking for Screen Recording alone takes 12 to 37 ms.
    @State private var permissions = TweakPermissions.assumed
    private let startTip = StartTip()
    /// The tip's group is there only while the tip is, so no empty group is left behind once it has gone.
    @State private var showsStartTip = false

    var body: some View {
        Form {
            Section {
                StatusRowReader(data: data, open: open)
            } header: {
                MacHero()
            }
            if showsStartTip {
                Section {
                    // A row of its group rather than a card on it, so the page keeps one surface.
                    TipView(startTip)
                        .tipBackground(.clear)
                }
            }
            Section {
                MetricRows(data: data, settings: settings, open: open)
            }
            TweaksSection(settings: settings, permissions: permissions, open: open)
            ActivitySection(data: data)
        }
        .formStyle(.grouped)
        .task {
            for await shows in startTip.shouldDisplayUpdates { showsStartTip = shows }
        }
        .onAppear { permissions = .current }
        .onChange(of: isWindowVisible) {
            if isWindowVisible { permissions = .current }
        }
        // Coming back from System Settings with a permission given, while the window stayed in view behind it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions = .current
        }
    }
}

// MARK: - This Mac

/// The Mac's own picture, its name and what it is, centred and without a group around them, as at the top of About.
private struct MacHero: View {
    /// As large as the picture in About.
    private static let imageSize: CGFloat = 128
    private static let imageInset: CGFloat = 14

    private let name: String
    private let facts: String

    init() {
        let info = SystemInfo.current
        // `MacBook Air (M2, 2022)` reads as About has it: the name large, what is in brackets under it.
        let product = info.productName ?? info.modelIdentifier
        var aside: String?
        if let opening = product.range(of: " ("), product.hasSuffix(")") {
            name = String(product[..<opening.lowerBound])
            aside = String(product[opening.upperBound..<product.index(before: product.endIndex)])
        } else {
            name = product
        }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let version =
            "macOS \(system.majorVersion).\(system.minorVersion)"
            + (system.patchVersion > 0 ? ".\(system.patchVersion)" : "")
        facts = [aside ?? info.chipName, Format.memorySize(info.totalMemory), version].joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            if let image = NSImage(named: NSImage.computerName) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.imageSize, height: Self.imageSize)
                    .accessibilityHidden(true)
            }
            Text(name)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
            Text(facts)
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        // The picture has room around the Mac drawn into it, which already sets it apart from the window's top.
        .padding(.top, -Self.imageInset)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}

/// What the line under the picture is about. The most pressing problem wins, and the load is taken over a few seconds
/// so that a brief spike does not change it.
private enum HomeCondition: Equatable {
    case lowBattery(minutesLeft: Int?)
    case diskAlmostFull(available: UInt64)
    case lowMemory
    case heavyProcessorLoad(busiestApp: String?)
    case heavyGraphicsLoad
    case waitingForData
    case calm

    private static let heavyLoad = 0.8
    private static let recentSamples = 5
    private static let lowCharge = 20
    private static let lowDiskShare = 0.9

    init(data: StatsLiveData) {
        if let battery = data.battery, battery.state == .discharging, battery.percent <= Self.lowCharge {
            self = .lowBattery(minutesLeft: battery.minutesRemaining)
        } else if let disk = data.disk?.main, disk.usedFraction >= Self.lowDiskShare {
            self = .diskAlmostFull(available: disk.available)
        } else if let memory = data.memory, memory.pressure != .normal {
            self = .lowMemory
        } else if let cpu = data.cpu, Self.recent(cpu.history, fallback: cpu.usage) >= Self.heavyLoad {
            self = .heavyProcessorLoad(busiestApp: AppActivity.top(data.topProcesses, count: 1).first?.name)
        } else if let gpu = data.gpu, Self.recent(gpu.history, fallback: gpu.usage ?? 0) >= Self.heavyLoad {
            self = .heavyGraphicsLoad
        } else if data.cpu == nil {
            self = .waitingForData
        } else {
            self = .calm
        }
    }

    private static func recent(_ history: [Float], fallback: Double) -> Double {
        let samples = history.suffix(recentSamples)
        guard !samples.isEmpty else { return fallback }
        return Double(samples.reduce(0, +)) / Double(samples.count)
    }

    var title: String {
        switch self {
        case .lowBattery: String(localized: "Battery Is Running Low")
        case .diskAlmostFull: String(localized: "Disk Is Almost Full")
        case .lowMemory: String(localized: "Memory Is Running Low")
        case .heavyProcessorLoad: String(localized: "Processor Is Under Heavy Load")
        case .heavyGraphicsLoad: String(localized: "Graphics Card Is Under Heavy Load")
        case .waitingForData: String(localized: "Looking at Your Mac…")
        case .calm: String(localized: "All Is Calm")
        }
    }

    var detail: String {
        switch self {
        case .lowBattery(let minutes):
            minutes.map { String(localized: "\(Format.hoursAndMinutes($0)) left") }
                ?? String(localized: "Connect the power adapter.")
        case .diskAlmostFull(let available):
            String(localized: "\(Format.fileSize(available)) free")
        case .lowMemory:
            String(localized: "Closing apps you are not using will help.")
        case .heavyProcessorLoad(let app):
            app.map { String(localized: "\($0) is working the hardest.") }
                ?? String(localized: "Your Mac may respond more slowly.")
        case .heavyGraphicsLoad:
            String(localized: "Games and video may run less smoothly.")
        case .waitingForData:
            " "
        case .calm:
            String(localized: "Your Mac is working as usual.")
        }
    }

    /// The page that says more about the problem.
    var page: MainPage? {
        switch self {
        case .lowBattery: .metric(.battery)
        case .diskAlmostFull: .metric(.disk)
        case .lowMemory: .metric(.memory)
        case .heavyProcessorLoad: .metric(.cpu)
        case .heavyGraphicsLoad: .metric(.gpu)
        case .waitingForData, .calm: nil
        }
    }
}

private struct StatusRowReader: View {
    let data: StatsLiveData
    let open: (MainPage) -> Void

    var body: some View {
        StatusRow(condition: HomeCondition(data: data), open: open).equatable()
    }
}

/// How the Mac is doing, as Software Update says whether the Mac is up to date: a symbol that tells it at a glance,
/// a sentence, and a button where there is something to look into.
private struct StatusRow: View, Equatable {
    /// As wide as the symbol in Software Update.
    private static let symbolWidth: CGFloat = 32

    let condition: HomeCondition
    let open: (MainPage) -> Void

    static func == (left: StatusRow, right: StatusRow) -> Bool {
        left.condition == right.condition
    }

    var body: some View {
        // Laid out by hand: a symbol this large inside a form's label pushes its text out of the row.
        HStack(spacing: 10) {
            symbol
                .frame(width: Self.symbolWidth, height: Self.symbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(condition.title)
                Text(condition.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            if let page = condition.page {
                Button("Details…") { open(page) }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var symbol: some View {
        switch condition {
        case .calm:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
        case .waitingForData:
            ProgressView()
                .controlSize(.small)
        default:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .symbolRenderingMode(.multicolor)
        }
    }
}

// MARK: - Figures

/// Every metric this Mac has, each a row that opens its page, as the rows of Privacy & Security say where each
/// setting is at.
private struct MetricRows: View {
    let data: StatsLiveData
    let settings: AppSettings
    let open: (MainPage) -> Void

    var body: some View {
        LoadRow(kind: .cpu, data: data, open: open)
        LoadRow(kind: .gpu, data: data, open: open)
        LoadRow(kind: .memory, data: data, open: open)
        DiskRow(data: data, open: open)
        NetworkRow(data: data, open: open)
        if MetricKind.available.contains(.battery) {
            BatteryRow(data: data, open: open)
        }
        if MetricKind.available.contains(.fans) {
            FansRow(data: data, settings: settings, open: open)
        }
    }
}

private struct LoadRow: View {
    let kind: MetricKind
    let data: StatsLiveData
    let open: (MainPage) -> Void

    var body: some View {
        let level: Double? =
            switch kind {
            case .cpu: data.cpu?.usage
            case .gpu: data.gpu?.usage
            default: data.memory?.usedFraction
            }
        var tint = Color.accentColor
        if kind == .memory, let pressure = data.memory?.pressure {
            switch pressure {
            case .normal: break
            case .warning: tint = .orange
            case .critical: tint = .red
            }
        }
        return MetricRow(
            kind: kind, detail: nil, value: level.map { Format.percent($0) }, level: level ?? 0, tint: tint, open: open
        )
        .equatable()
    }
}

private struct DiskRow: View {
    let data: StatsLiveData
    let open: (MainPage) -> Void

    var body: some View {
        let main = data.disk?.main
        MetricRow(
            kind: .disk,
            detail: main.map {
                String(localized: "\(Format.fileSize($0.available)) free of \(Format.fileSize($0.total))")
            },
            value: main.map { Format.percent($0.usedFraction) }, level: main?.usedFraction ?? 0,
            tint: main.map {
                $0.usedFraction >= 0.9
                    ? Color(nsColor: DiskDetailView.color(forUsedFraction: $0.usedFraction)) : .accentColor
            } ?? .accentColor,
            open: open
        )
        .equatable()
    }
}

private struct NetworkRow: View {
    let data: StatsLiveData
    let open: (MainPage) -> Void

    var body: some View {
        MetricRow(
            kind: .network, detail: nil,
            value: data.network.map { "↓ \(Format.rate($0.downRate))   ↑ \(Format.rate($0.upRate))" },
            open: open
        )
        .equatable()
    }
}

private struct BatteryRow: View {
    let data: StatsLiveData
    let open: (MainPage) -> Void
    /// Low Power Mode colours the bar, and it changes without a new reading of the battery.
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    var body: some View {
        let battery = data.battery
        MetricRow(
            kind: .battery, detail: battery.map(Self.state),
            value: battery.map { Format.percent(Double($0.percent) / 100) },
            level: Double(battery?.percent ?? 0) / 100,
            tint: Color(
                nsColor: BatteryDetailView.color(
                    forCharge: battery?.percent ?? 100, isLowPower: isLowPower)),
            open: open
        )
        .equatable()
        .onReceive(
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)
        ) { _ in
            isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    private static func state(of battery: BatterySnapshot) -> String {
        let time = battery.minutesRemaining.map(Format.hoursAndMinutes)
        return switch battery.state {
        case .charging: time.map { String(localized: "\($0) until full") } ?? String(localized: "Charging")
        case .charged: String(localized: "Fully charged")
        case .notCharging: String(localized: "Plugged in, not charging")
        case .discharging: time.map { String(localized: "\($0) left") } ?? String(localized: "On battery")
        }
    }
}

/// What the fans were told to do, from the settings alone: reading them would need sensors that are not free.
private struct FansRow: View {
    let data: StatsLiveData
    let settings: AppSettings
    let open: (MainPage) -> Void

    var body: some View {
        MetricRow(kind: .fans, detail: nil, value: profileName, open: open)
            .equatable()
    }

    private var profileName: String {
        let fans = settings.fanSettings
        let plan = fans.plan(onBattery: data.battery?.state == .discharging)
        switch fans.profile(of: plan) {
        case .builtIn(let profile): return profile.title
        case .saved(let id): return fans.savedProfiles.first { $0.id == id }?.name ?? String(localized: "Own Settings")
        case nil: return String(localized: "Own Settings")
        }
    }
}

private struct MetricRow: View, Equatable {
    private static let barWidth: CGFloat = 110
    /// Half a point along the bar. Memory moves by less all the time, and redrawing for it shows nothing.
    nonisolated private static let barSteps = 220.0
    /// As wide as "100 %", so that the bars above and below line up.
    private static let valueWidth: CGFloat = 42

    let kind: MetricKind
    let detail: String?
    let value: String?
    /// How full its bar is. Nil for a metric with no natural top, such as a speed, which gets no bar.
    var level: Double?
    var tint = Color.accentColor
    let open: (MainPage) -> Void

    nonisolated static func == (left: MetricRow, right: MetricRow) -> Bool {
        left.kind == right.kind && left.detail == right.detail && left.value == right.value
            && left.level.map(step) == right.level.map(step) && left.tint == right.tint
    }

    nonisolated private static func step(_ level: Double) -> Double {
        (level * barSteps).rounded()
    }

    var body: some View {
        LinkRow(
            symbol: kind.symbol, symbolScale: kind == .battery ? .small : .medium, title: Text(kind.pageTitle),
            detail: detail.map { Text($0) }, action: { open(.metric(kind)) }
        ) {
            HStack(spacing: 10) {
                if let level {
                    LevelBar(level: level, tint: tint, width: Self.barWidth)
                }
                Text(value ?? "—")
                    .monospacedDigit()
                    .frame(minWidth: level != nil ? Self.valueWidth : nil, alignment: .trailing)
            }
        }
    }
}

/// How full something is: a solid colour on a neutral track, as in the popovers and in the bar of Storage. It keeps
/// its colour in a window in the background, as that bar does, which the system's own gauge does not.
private struct LevelBar: View {
    private static let height: CGFloat = 6

    let level: Double
    let tint: Color
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.quaternary)
            Capsule()
                .fill(tint)
                // Nothing on it still shows a dot, as an empty bar looks unfinished.
                .frame(width: max(width * min(max(level, 0), 1), Self.height))
        }
        .frame(width: width, height: Self.height)
    }
}

// MARK: - Tweaks

/// Whether the permissions the tweaks need are there. Asking costs a call to the system each, so it is done when the
/// page appears rather than all the time.
private struct TweakPermissions: Equatable {
    var accessibility: Bool
    var screenRecording: Bool
    /// The Finder menu's extension, which can be turned off in System Settings while the tweak stays on.
    var finderExtension: Bool

    /// Until the page appears and asks.
    static let assumed = TweakPermissions(accessibility: true, screenRecording: true, finderExtension: true)

    static var current: TweakPermissions {
        TweakPermissions(
            accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess(),
            finderExtension: FinderExtension.isEnabled)
    }
}

/// Every tweak, with what it does and whether it is on, as the list of apps under Saved to iCloud says which ones
/// are on. A tweak that is on but cannot work says so here, and its page says why.
private struct TweaksSection: View {
    let settings: AppSettings
    let permissions: TweakPermissions
    let open: (MainPage) -> Void

    var body: some View {
        Section("Tweaks") {
            TweakRow(
                page: .windowSwitcher, title: MainPage.windowSwitcher.title,
                detail: String(localized: "Command-Tab with a preview of every window"),
                status: status(
                    isOn: settings.windowSwitcherEnabled,
                    isAllowed: permissions.accessibility
                        && (permissions.screenRecording || !settings.switcherTuning.showsPreviews)),
                open: open
            )
            .equatable()
            TweakRow(
                page: .dock, title: MainPage.dock.title,
                detail: String(localized: "Windows over each Dock icon, and a click to minimize"),
                status: status(
                    isOn: settings.dockEnabled,
                    isAllowed: permissions.accessibility
                        && (permissions.screenRecording || !settings.dockTuning.showsPanel)),
                open: open
            )
            .equatable()
            TweakRow(
                page: .mouse, title: MainPage.mouse.title,
                detail: String(localized: "No acceleration, the wheel as on Windows, side buttons"),
                status: status(isOn: settings.mouseEnabled, isAllowed: permissions.accessibility),
                open: open
            )
            .equatable()
            TweakRow(
                page: .finderCut, title: MainPage.finderCut.title,
                detail: String(localized: "Command-X and Command-V move files"),
                status: status(isOn: settings.finderCutEnabled, isAllowed: permissions.accessibility),
                open: open
            )
            .equatable()
            TweakRow(
                page: .finderMenu, title: MainPage.finderMenu.title,
                detail: String(localized: "New File, Copy Path and Open in Terminal"),
                status: status(isOn: settings.finderMenuEnabled, isAllowed: permissions.finderExtension),
                open: open
            )
            .equatable()
            TweakRow(
                page: .languageSwitch, title: MainPage.languageSwitch.title,
                detail: String(localized: "A short press of Fn changes the input source"),
                status: status(isOn: settings.languageSwitchEnabled, isAllowed: permissions.accessibility),
                open: open
            )
            .equatable()
        }
    }

    private func status(isOn: Bool, isAllowed: Bool) -> TweakStatus {
        guard isOn else { return .off }
        return isAllowed ? .on : .needsPermission
    }
}

nonisolated private enum TweakStatus {
    case on, off, needsPermission
}

private struct TweakRow: View, Equatable {
    let page: MainPage
    let title: String
    let detail: String
    let status: TweakStatus
    let open: (MainPage) -> Void

    nonisolated static func == (left: TweakRow, right: TweakRow) -> Bool {
        left.title == right.title && left.detail == right.detail && left.status == right.status
    }

    var body: some View {
        LinkRow(symbol: page.symbol, title: Text(title), detail: Text(detail), action: { open(page) }) {
            switch status {
            case .on: Text("On")
            case .off: Text("Off")
            case .needsPermission:
                Label {
                    Text("Needs Permission")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }
        }
    }
}

// MARK: - Apps

/// What is working the hardest. A section of the form only stays one as a direct part of it, so nothing here can be
/// wrapped to skip unchanged updates. The data model does that instead: the list only changes every couple of seconds.
private struct ActivitySection: View {
    private static let processCount = 3

    let data: StatsLiveData

    var body: some View {
        let activities = AppActivity.top(data.topProcesses, count: Self.processCount)
        if !activities.isEmpty {
            Section("Working the Hardest") {
                ForEach(activities) { ProcessRow(activity: $0).equatable() }
            }
        }
    }
}

/// One app with all its helpers counted together, because people know apps rather than `plugin-container`.
private struct AppActivity: Identifiable, Equatable {
    let id: String
    let name: String
    let appPath: String?
    let load: Double

    /// Asking the file system for a name takes time, and these do not change while the window is open.
    private static var appNames: [String: String] = [:]

    static func top(_ entries: [ProcessEntry], count: Int) -> [AppActivity] {
        let groups = Dictionary(grouping: entries.filter { $0.cpu > 0 }) { $0.appBundlePath ?? "pid.\($0.pid)" }
        let activities = groups.compactMap { key, members -> AppActivity? in
            guard let first = members.first else { return nil }
            let path = first.appBundlePath
            return AppActivity(
                id: key,
                name: path.map(appName(at:)) ?? first.name,
                appPath: path,
                load: members.reduce(0) { $0 + $1.cpu }
            )
        }
        return Array(activities.sorted { $0.load > $1.load }.prefix(count))
    }

    private static func appName(at path: String) -> String {
        if let known = appNames[path] { return known }
        let name = FileManager.default.displayName(atPath: path)
        let result = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        appNames[path] = result
        return result
    }
}

private struct ProcessRow: View, Equatable {
    private static let iconSize: CGFloat = 20
    /// Icons hold many sizes and take time to find, and this process lives only as long as its window.
    private static var icons: [String: NSImage] = [:]
    private static let executableIcon = sized(NSWorkspace.shared.icon(for: .unixExecutable))

    let activity: AppActivity

    var body: some View {
        LabeledContent {
            Text(Format.processLoad(activity.load))
                .monospacedDigit()
        } label: {
            Label {
                Text(activity.name)
                    .lineLimit(1)
            } icon: {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    // In the symbols' column of the rows above, so that the names line up.
                    .frame(width: LinkRow<EmptyView>.symbolWidth)
                    .accessibilityHidden(true)
            }
        }
    }

    private var icon: NSImage {
        guard let path = activity.appPath else { return Self.executableIcon }
        if let known = Self.icons[path] { return known }
        let made = Self.sized(NSWorkspace.shared.icon(forFile: path))
        Self.icons[path] = made
        return made
    }

    private static func sized(_ icon: NSImage) -> NSImage {
        icon.size = NSSize(width: iconSize, height: iconSize)
        return icon
    }
}
