import AppKit
import Charts
import FanControlCore
import SwiftUI
import SystemMetrics

extension FanMode {
    var title: String {
        switch self {
        case .system: String(localized: "fan.mode.system", defaultValue: "System")
        case .fixed: String(localized: "fan.mode.fixed", defaultValue: "Fixed")
        case .curve: String(localized: "fan.mode.curve", defaultValue: "Curve")
        }
    }
}

extension FanMode {
    /// What a mode means, under its name.
    var detail: String {
        switch self {
        case .system: String(localized: "macOS decides how fast the fans spin, as if Tweakly were not here.")
        case .fixed: String(localized: "One speed all the time.")
        case .curve: String(localized: "The speed follows a temperature.")
        }
    }
}

extension FanSensor {
    var title: String {
        switch self {
        case .hottest: String(localized: "Hottest of All")
        case .hottestCPU: String(localized: "Processor, hottest")
        case .averageCPU: String(localized: "Processor, typical")
        case .gpu: String(localized: "Graphics, hottest")
        case .battery: String(localized: "metric.battery", defaultValue: "Battery")
        }
    }
}

/// What the fans do, on their page in the window. Built as System Settings builds its pages: every setting has a row of its
/// own with its name on the left and its control on the right, what explains a group goes under it, and the buttons that are
/// about the whole page stand alone at the bottom on the right, as Options does on Battery. Everything else on that page is
/// as for any metric.
struct FanControlSections: View {
    /// Other apps that set fans. Two at once overwrite each other, whichever is right.
    private static let rivals = [
        "com.crystalidea.macsfancontrol": "Macs Fan Control", "com.tunabellysoftware.tgpro": "TG Pro",
        "com.bjango.istatmenus": "iStat Menus", "eu.exelban.Stats": "Stats",
    ]

    @Bindable var settings: AppSettings
    let isWindowVisible: Bool
    @State private var feed = FanPageFeed()
    @State private var client = FanHelperClient()
    @State private var isInstalled = FanHelperClient.isInstalled
    @State private var isOutdated = false
    @State private var helperError: String?
    @State private var editsBattery = false
    @State private var selectedFan = 0
    @State private var isShowingAdvanced = false
    @State private var isNamingProfile = false
    @State private var profileName = ""
    @State private var rival: String?
    @State private var selectedPoint = 0
    /// How many of this page's sections are on screen.
    @State private var shownSections = 0

    var body: some View {
        Group {
            helperSection
            nowSection
            controlSection
                .disabled(!isReady)
            switch setup.wrappedValue.mode {
            case .system:
                EmptyView()
            case .fixed:
                fixedSection
                    .disabled(!isReady)
            case .curve:
                curveSections
                    .disabled(!isReady)
            }
            optionsSection
                .disabled(!isReady)
        }
        // What is attached to a group goes to each of its sections, and a form shows its sections lazily, so each
        // section appears and disappears as it scrolls. The page's live values and its checks follow all of them
        // together: on while any is on screen, once for the page rather than once for each section.
        .onAppear {
            shownSections += 1
            guard shownSections == 1 else { return }
            feed.setVisible(isWindowVisible)
            refreshHelper()
            rival =
                Self.rivals.first { id, _ in
                    !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
                }?.value
        }
        .onDisappear {
            shownSections = max(shownSections - 1, 0)
            if shownSections == 0 { feed.setVisible(false) }
        }
        // Reading the sensors for a page nobody can see is exactly the work this app promises not to do.
        .onChange(of: isWindowVisible) { _, isVisible in feed.setVisible(isVisible && shownSections > 0) }
        .onChange(of: selectedFan) { selectedPoint = 0 }
        .onChange(of: editsBattery) { selectedPoint = 0 }
    }

    private var isReady: Bool { isInstalled && !isOutdated }

    /// Asked of the registry once: the page draws again with every reading of the fans.
    private static let hasBattery = MetricKind.available.contains(.battery)

    private var fanCount: Int {
        #if TWEAKLY_AUTOMATION
            // To look at the page as it is with two fans, on a Mac with none.
            // Unless there are fans to count, such as the made-up one of a copy taking pictures.
            if UserDefaults.standard.bool(forKey: "fanHelperAssumed"), feed.snapshot?.fans.isEmpty ?? true {
                return 2
            }
        #endif
        return feed.snapshot?.fans.count ?? 2
    }

    private var plan: FanPlan {
        editsBattery ? settings.fanSettings.battery ?? settings.fanSettings.adapter : settings.fanSettings.adapter
    }

    private func setPlan(_ newPlan: FanPlan) {
        var fans = settings.fanSettings
        if editsBattery { fans.battery = newPlan } else { fans.adapter = newPlan }
        settings.fanSettings = fans
    }

    private func updatePlan(_ change: (inout FanPlan) -> Void) {
        var changed = plan
        change(&changed)
        setPlan(changed)
    }

    private var setup: Binding<FanSetup> {
        Binding(
            get: { plan.setup(ofFan: selectedFan) },
            set: { value in updatePlan { $0.setSetup(value, ofFan: selectedFan, fanCount: fanCount) } })
    }

    // MARK: The helper

    @ViewBuilder private var helperSection: some View {
        if !isReady || !notices.isEmpty {
            Section {
                if !isReady {
                    LabeledContent {
                        Button(isOutdated ? "Update…" : "Install…", action: installHelper)
                    } label: {
                        Text("Fan Helper")
                        Text(
                            "Only an administrator can change the speed of the fans, so macOS asks for a password once."
                        )
                    }
                }
                ForEach(notices, id: \.self) { notice in
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notices: [String] {
        var notices: [String] = []
        if let helperError { notices.append(helperError) }
        if let message = feed.driverStatus.message { notices.append(message) }
        if let rival {
            notices.append(String(localized: "\(rival) is running. Two apps setting the fans overwrite each other."))
        }
        return notices
    }

    private func refreshHelper() {
        isInstalled = FanHelperClient.isInstalled
        guard isInstalled else {
            isOutdated = false
            return
        }
        client.version { version in
            // A newer helper, left by a newer copy of the app, answers everything this one asks. One that does not
            // answer at all is most likely signed differently from this copy, which installing it again puts right.
            isOutdated = version.map { $0 < FanHelper.currentVersion } ?? true
            client.close()
        }
    }

    private func installHelper() {
        helperError = FanHelperInstaller.install()
        refreshHelper()
    }

    private func removeHelper() {
        let chosen = settings.fanSettings
        var fans = chosen
        fans.adapter = FanPlan()
        fans.battery = nil
        settings.fanSettings = fans
        helperError = FanHelperInstaller.uninstall()
        refreshHelper()
        // Someone pressed Cancel at the request for a password, or it failed, so what was chosen goes on as before.
        if isInstalled { settings.fanSettings = chosen }
    }

    // MARK: What is happening now

    @ViewBuilder private var nowSection: some View {
        if let snapshot = feed.snapshot, !snapshot.fans.isEmpty {
            Section {
                ForEach(snapshot.fans, id: \.index) { fan in
                    FanNowRow(fan: fan)
                }
                ForEach(shownSensors(in: snapshot.temperatures), id: \.self) { sensor in
                    if let reading = sensor.reading(in: snapshot.temperatures) {
                        LabeledContent(sensor.title, value: Format.temperature(celsius: reading))
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Now")
            }
        }
    }

    /// The readings worth a row. "Hottest of all" only repeats one of them.
    private func shownSensors(in temperatures: FanTemperatures) -> [FanSensor] {
        [.hottestCPU, .averageCPU, .gpu, .battery].filter { $0.reading(in: temperatures) != nil }
    }

    // MARK: Profile and mode

    private var controlSection: some View {
        Section {
            // In the order they apply: what is being edited comes before what is chosen for it.
            if settings.fanSettings.battery != nil {
                segmentedRow("Settings For", selection: $editsBattery) {
                    Text("Power Adapter").tag(false)
                    Text(FanSensor.battery.title).tag(true)
                }
            }
            Picker("Profile", selection: chosenProfile) {
                ForEach(FanProfile.allCases) { profile in
                    Text(profile.title).tag(Optional(FanProfileChoice.builtIn(profile)))
                }
                if !settings.fanSettings.savedProfiles.isEmpty {
                    Divider()
                    ForEach(settings.fanSettings.savedProfiles) { saved in
                        Text(saved.name).tag(Optional(FanProfileChoice.saved(saved.id)))
                    }
                }
                if chosenProfile.wrappedValue == nil {
                    Divider()
                    Text("Own Settings").tag(FanProfileChoice?.none)
                }
            }
            if !plan.isLinked, fanCount > 1 {
                segmentedRow("Fan", selection: $selectedFan) {
                    ForEach(0..<fanCount, id: \.self) { index in
                        Text(FanSnapshot.fanName(index)).tag(index)
                    }
                }
            }
            LabeledContent {
                Picker("Mode", selection: setup.mode) {
                    ForEach(FanMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("Mode")
                Text(setup.wrappedValue.mode.detail)
            }
            if setup.wrappedValue.mode == .curve {
                Picker("Follows", selection: setup.sensor) {
                    ForEach(FanSensor.allCases.filter { $0 != .battery || Self.hasBattery }) { sensor in
                        Text(sensor.title).tag(sensor)
                    }
                }
            }
        } header: {
            Text("Control")
        }
    }

    private func segmentedRow<Value: Hashable>(
        _ title: LocalizedStringKey, selection: Binding<Value>, @ViewBuilder choices: () -> some View
    ) -> some View {
        LabeledContent(title) {
            Picker(title, selection: selection, content: choices)
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
        }
    }

    private var chosenProfile: Binding<FanProfileChoice?> {
        Binding(
            get: { settings.fanSettings.profile(of: plan) },
            set: { choice in
                guard let choice, let chosen = settings.fanSettings.plan(of: choice) else { return }
                selectedFan = 0
                selectedPoint = 0
                setPlan(chosen)
            })
    }

    private func saveProfile() {
        let name = profileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        settings.fanSettings.savedProfiles.append(SavedFanProfile(id: UUID().uuidString, name: name, plan: plan))
    }

    // MARK: What each mode needs

    private var fixedSection: some View {
        Section {
            LabeledContent {
                HStack {
                    Slider(value: setup.fixedPercent, in: FanCurve.percents, step: 5)
                        .labelsHidden()
                        .frame(minWidth: 180)
                    Text(Format.percent(setup.wrappedValue.fixedPercent / 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            } label: {
                Text("Speed")
                Text("0 % is the slowest a fan can spin, not standing still.")
            }
            ForEach(feed.snapshot?.fans ?? [], id: \.index) { fan in
                let limits = FanLimits(minimum: fan.minimum, maximum: fan.maximum)
                LabeledContent(
                    FanSnapshot.fanName(fan.index),
                    value: Format.rpm(limits.rpm(atPercent: setup.wrappedValue.fixedPercent))
                )
                .monospacedDigit()
            }
        }
    }

    @ViewBuilder private var curveSections: some View {
        Section {
            FanCurveChart(
                curve: setup.curve, selected: $selectedPoint,
                temperature: feed.snapshot.flatMap { setup.wrappedValue.sensor.reading(in: $0.temperatures) })
        } footer: {
            Text(
                "Drag a point to move it, and click an empty spot to add one. Below the first point the system keeps the fans, which often means they stand still."
            )
            .foregroundStyle(.secondary)
        }
        Section("Selected Point") {
            FanCurvePointRows(curve: setup.curve, selected: $selectedPoint)
        }
    }

    // MARK: The rest

    private var optionsSection: some View {
        Section {
            if fanCount > 1 { separateFansToggle }
            if Self.hasBattery { batteryToggle }
        } footer: {
            HStack {
                Spacer()
                if case .saved(let id) = chosenProfile.wrappedValue,
                    let saved = settings.fanSettings.savedProfiles.first(where: { $0.id == id })
                {
                    Button("Delete “\(saved.name)”") {
                        settings.fanSettings.savedProfiles.removeAll { $0.id == id }
                    }
                }
                if chosenProfile.wrappedValue == nil {
                    Button("Save as Profile…") {
                        profileName = ""
                        isNamingProfile = true
                    }
                }
                Button("Advanced…") { isShowingAdvanced = true }
            }
            // On the one view that holds their buttons: a group or a section hands what is attached to it to each of
            // its sections or rows, and each would present its own copy.
            .sheet(isPresented: $isShowingAdvanced) {
                FanAdvancedSheet(settings: settings, isInstalled: isInstalled, remove: removeHelper)
            }
            .alert("Save Profile", isPresented: $isNamingProfile) {
                TextField("Name", text: $profileName)
                Button("Save", action: saveProfile)
                    .disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var separateFansToggle: some View {
        Toggle(
            "Set Each Fan Separately",
            isOn: Binding(
                get: { !plan.isLinked },
                set: { separate in
                    selectedFan = 0
                    updatePlan {
                        $0.isLinked = !separate
                        if separate, $0.separate.isEmpty {
                            $0.separate = Array(repeating: $0.shared, count: fanCount)
                        }
                    }
                }))
    }

    private var batteryToggle: some View {
        Toggle(
            "Different Settings on Battery",
            isOn: Binding(
                get: { settings.fanSettings.battery != nil },
                set: { isOn in
                    editsBattery = false
                    settings.fanSettings.battery = isOn ? settings.fanSettings.adapter : nil
                }))
    }
}

/// One fan, as Macs Fan Control's table has it and in the manner of a row in System Settings: its limits, where it is
/// between them, and its speed.
private struct FanNowRow: View {
    private static var barWidth: CGFloat { 120 }

    let fan: FanReading

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                ProgressView(value: fan.maximum > 0 ? min(fan.actual / fan.maximum, 1) : 0)
                    .progressViewStyle(.linear)
                    .frame(width: Self.barWidth)
                    .accessibilityHidden(true)
                Text(fan.actual < 1 ? String(localized: "Stopped") : Format.rpm(fan.actual))
                    .monospacedDigit()
                    .frame(minWidth: 84, alignment: .trailing)
            }
        } label: {
            Text(FanSnapshot.fanName(fan.index))
            Text("From \(Format.rpm(fan.minimum)) to \(Format.rpm(fan.maximum))")
        }
    }
}

/// A curve to drag about, as a line, framed as Battery's charts are in System Settings: the scale on the right, solid lines
/// across and dotted ones down, and a pale band for the part that is different. A line reads better here than that
/// page's bars. Changes are kept here until the finger lifts, so that the fans and the preferences hear of one change
/// rather than
/// sixty a second.
private struct FanCurveChart: View {
    /// How near a click has to be to a point to take hold of it.
    private static var reach: CGFloat { 18 }
    private static var height: CGFloat { 190 }

    @Binding var curve: FanCurve
    @Binding var selected: Int
    let temperature: Double?

    @State private var draft: FanCurve?
    @State private var held: Int?
    @State private var isDragging = false
    @State private var startedOnEmpty = false

    private var shown: FanCurve { draft ?? curve }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fan Speed")
                .fontWeight(.semibold)
            chart
                .frame(height: Self.height)
                .accessibilityLabel("Fan curve")
        }
        .padding(.vertical, 6)
    }

    private var chart: some View {
        Chart {
            systemBand
            lineMarks
            nowMark
            pointMarks
        }
        .chartXScale(domain: FanCurve.temperatures)
        .chartYScale(domain: FanCurve.percents)
        .chartPlotStyle { plot in
            plot.border(Color.secondary.opacity(0.35), width: 0.5)
        }
        .chartXAxis { temperatureAxis }
        .chartYAxis { speedAxis }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .gesture(drag(proxy: proxy, geometry: geometry))
            }
        }
    }

    /// The part of the chart where the system keeps the fans, in the manner of Battery's bands for charging.
    @ChartContentBuilder private var systemBand: some ChartContent {
        if let first = shown.points.first, first.temperature > FanCurve.temperatures.lowerBound {
            RectangleMark(
                xStart: .value("From", FanCurve.temperatures.lowerBound), xEnd: .value("To", first.temperature)
            )
            .foregroundStyle(Color.secondary.opacity(0.12))
            .annotation(position: .overlay) {
                Text(FanMode.system.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The line of the curve, carried on flat to the end of the scale, as the fan stays at the last point's speed.
    private var linePoints: [FanCurvePoint] {
        let points = shown.points
        guard let last = points.last else { return [] }
        // A last point at the end of the scale already reaches it, and a second one there would repeat its identity.
        guard last.temperature < FanCurve.temperatures.upperBound else { return points }
        return points + [FanCurvePoint(temperature: FanCurve.temperatures.upperBound, percent: last.percent)]
    }

    @ChartContentBuilder private var lineMarks: some ChartContent {
        ForEach(linePoints, id: \.temperature) { point in
            areaMark(point)
        }
        ForEach(linePoints, id: \.temperature) { point in
            lineMark(point)
        }
    }

    private func areaMark(_ point: FanCurvePoint) -> some ChartContent {
        let temperature: Double = point.temperature
        let percent: Double = point.percent
        return AreaMark(x: .value("Temperature", temperature), y: .value("Speed", percent))
            .foregroundStyle(Color.accentColor.opacity(0.14))
    }

    private func lineMark(_ point: FanCurvePoint) -> some ChartContent {
        let temperature: Double = point.temperature
        let percent: Double = point.percent
        return LineMark(x: .value("Temperature", temperature), y: .value("Speed", percent))
            .foregroundStyle(Color.accentColor)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    @ChartContentBuilder private var nowMark: some ChartContent {
        if let temperature, FanCurve.temperatures.contains(temperature) {
            RuleMark(x: .value("Now", temperature))
                .foregroundStyle(Color.primary)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .top, spacing: 2) {
                    Text(Format.temperature(celsius: temperature))
                        .font(.caption)
                        .monospacedDigit()
                }
        }
    }

    @ChartContentBuilder private var pointMarks: some ChartContent {
        ForEach(Array(shown.points.enumerated()), id: \.offset) { index, point in
            PointMark(x: .value("Temperature", point.temperature), y: .value("Speed", point.percent))
                .symbol {
                    FanCurveHandle(isSelected: index == selected)
                }
        }
    }

    private var temperatureAxis: some AxisContent {
        AxisMarks(values: .stride(by: 10)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            AxisValueLabel {
                if let degrees = value.as(Double.self) { Text(verbatim: "\(Format.degrees(celsius: degrees))°") }
            }
        }
    }

    private var speedAxis: some AxisContent {
        AxisMarks(position: .trailing, values: [0.0, 25.0, 50.0, 75.0, 100.0]) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
            AxisValueLabel {
                if let percent = value.as(Double.self), percent.truncatingRemainder(dividingBy: 50) == 0 {
                    Text(Format.percent(percent / 100))
                }
            }
        }
    }

    private func drag(proxy: ChartProxy, geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let plot = proxy.plotFrame.map({ geometry[$0] }) else { return }
                if !isDragging {
                    isDragging = true
                    held = pointIndex(near: value.startLocation, proxy: proxy, plot: plot)
                    startedOnEmpty = held == nil
                    if let held { selected = held }
                }
                guard let held, let point = point(at: value.location, proxy: proxy, plot: plot) else { return }
                var edited = draft ?? curve
                edited.move(pointAt: held, to: point)
                draft = edited
            }
            .onEnded { value in
                if let draft { curve = draft }
                if startedOnEmpty, let plot = proxy.plotFrame.map({ geometry[$0] }),
                    let point = point(at: value.location, proxy: proxy, plot: plot)
                {
                    var edited = curve
                    if let index = edited.add(point) {
                        curve = edited
                        selected = index
                    }
                }
                draft = nil
                held = nil
                isDragging = false
                startedOnEmpty = false
            }
    }

    private func pointIndex(near location: CGPoint, proxy: ChartProxy, plot: CGRect) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in curve.points.enumerated() {
            guard let x = proxy.position(forX: point.temperature), let y = proxy.position(forY: point.percent) else {
                continue
            }
            let distance = hypot(x + plot.minX - location.x, y + plot.minY - location.y)
            if distance <= Self.reach, distance < best?.distance ?? .infinity { best = (index, distance) }
        }
        return best?.index
    }

    /// Whole degrees and percents: anything finer cannot be told on a chart this size.
    private func point(at location: CGPoint, proxy: ChartProxy, plot: CGRect) -> FanCurvePoint? {
        guard let temperature = proxy.value(atX: location.x - plot.minX, as: Double.self),
            let percent = proxy.value(atY: location.y - plot.minY, as: Double.self)
        else { return nil }
        return FanCurvePoint(temperature: temperature.rounded(), percent: min(max(percent.rounded(), 0), 100))
    }
}

/// The point chosen on the chart, in rows of its own: exact numbers, and a way there with the keyboard.
private struct FanCurvePointRows: View {
    @Binding var curve: FanCurve
    @Binding var selected: Int

    private var index: Int { min(selected, max(curve.points.count - 1, 0)) }

    private var point: FanCurvePoint {
        curve.points.indices.contains(index) ? curve.points[index] : FanCurvePoint(temperature: 0, percent: 0)
    }

    var body: some View {
        // The chart is for the pointer; with the keyboard or VoiceOver a point is chosen and added here.
        Picker("Point", selection: $selected) {
            ForEach(curve.points.indices, id: \.self) { index in
                Text(String(localized: "\(String(index + 1)) of \(String(curve.points.count))")).tag(index)
            }
        }
        LabeledContent("Temperature") {
            value(Format.temperature(celsius: point.temperature)) {
                Stepper(
                    "Temperature",
                    value: Binding(
                        get: { point.temperature },
                        set: { edit(FanCurvePoint(temperature: $0, percent: point.percent)) }),
                    in: FanCurve.temperatures, step: 1)
            }
        }
        LabeledContent("Speed") {
            value(Format.percent(point.percent / 100)) {
                Stepper(
                    "Speed",
                    value: Binding(
                        get: { point.percent },
                        set: { edit(FanCurvePoint(temperature: point.temperature, percent: $0)) }),
                    in: FanCurve.percents, step: 5)
            }
        }
        LabeledContent {
            HStack {
                Button("Add Point", action: addPoint)
                    .disabled(newPoint == nil)
                Button("Remove") {
                    var edited = curve
                    edited.remove(pointAt: index)
                    curve = edited
                    selected = max(index - 1, 0)
                }
                .disabled(curve.points.count <= FanCurve.fewestPoints)
            }
        } label: {
            Text("Points")
            Text("A curve needs at least two points.")
        }
    }

    /// Halfway to the next point, or a little hotter than the last one at its speed.
    private var newPoint: FanCurvePoint? {
        guard curve.points.count < FanCurve.mostPoints, curve.points.indices.contains(index) else { return nil }
        let point = curve.points[index]
        if index + 1 < curve.points.count {
            let next = curve.points[index + 1]
            let temperature = ((point.temperature + next.temperature) / 2).rounded()
            guard temperature - point.temperature >= FanCurve.smallestGap,
                next.temperature - temperature >= FanCurve.smallestGap
            else { return nil }
            return FanCurvePoint(temperature: temperature, percent: ((point.percent + next.percent) / 2).rounded())
        }
        let temperature = min(point.temperature + 5, FanCurve.temperatures.upperBound)
        guard temperature - point.temperature >= FanCurve.smallestGap else { return nil }
        return FanCurvePoint(temperature: temperature, percent: point.percent)
    }

    private func addPoint() {
        guard let newPoint else { return }
        var edited = curve
        if let added = edited.add(newPoint) {
            curve = edited
            selected = added
        }
    }

    private func value(_ text: String, @ViewBuilder stepper: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            stepper()
                .labelsHidden()
        }
    }

    private func edit(_ point: FanCurvePoint) {
        var edited = curve
        edited.move(pointAt: index, to: point)
        curve = edited
    }
}

/// What can be taken hold of on the chart. White with an accent ring, so that it stands out from the bars under it.
private struct FanCurveHandle: View {
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(.white)
            .strokeBorder(Color.accentColor, lineWidth: isSelected ? 3 : 2)
            .frame(width: isSelected ? 14 : 11, height: isSelected ? 14 : 11)
            .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
    }
}

/// What most people never need: how a fan gets from one speed to another, and the line it never crosses.
private struct FanAdvancedSheet: View {
    @Bindable var settings: AppSettings
    let isInstalled: Bool
    let remove: () -> Void
    @State private var isConfirmingRemoval = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailsSheet(
            resetTitle: "Restore Defaults", canReset: settings.fanSettings.tuning != FanTuning(),
            reset: { settings.fanSettings.tuning = FanTuning() }
        ) {
            Section("Response") {
                row(
                    "Smoothing",
                    detail:
                        "How long a temperature has to last to count in full. A short spike then does not reach the fans.",
                    value: $settings.fanSettings.tuning.smoothingSeconds, in: FanTuning.smoothingRange, step: 5
                ) { String(localized: "\(String(Int($0))) s") }
                row(
                    "Fastest Rise", detail: "How quickly a fan may speed up.",
                    value: $settings.fanSettings.tuning.fastestRise, in: FanTuning.riseRange, step: 50, text: perSecond)
                row(
                    "Fastest Fall",
                    detail: "How quickly a fan may slow down. A fan that drops away is what people notice.",
                    value: $settings.fanSettings.tuning.fastestFall, in: FanTuning.fallRange, step: 50, text: perSecond)
                row(
                    "Smallest Change",
                    detail: "A smaller change of speed is left alone, so that a fan does not hunt around its target.",
                    value: $settings.fanSettings.tuning.smallestChange, in: FanTuning.changeRange, step: 10
                ) { Format.rpm($0) }
            }
            Section("Safety") {
                row(
                    "Emergency Temperature",
                    detail: "At this temperature the fans run at full speed, until the Mac is well below it.",
                    value: $settings.fanSettings.tuning.emergencyTemperature, in: FanTuning.emergencyRange, step: 1
                ) { Format.temperature(celsius: $0) }
            }
            if isInstalled {
                Section("Fan Helper") {
                    LabeledContent {
                        Button("Remove…") { isConfirmingRemoval = true }
                    } label: {
                        Text("Remove Fan Helper")
                        Text("The system takes the fans back, and macOS asks for a password.")
                    }
                }
            }
        }
        .confirmationDialog("Remove the fan helper?", isPresented: $isConfirmingRemoval) {
            Button("Remove", role: .destructive) {
                dismiss()
                remove()
            }
        }
    }

    private func perSecond(_ value: Double) -> String {
        String(localized: "\(String(Int(value))) rpm a second")
    }

    private func row(
        _ title: LocalizedStringKey, detail: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>,
        step: Double, text: @escaping (Double) -> String
    ) -> some View {
        LabeledContent {
            HStack {
                Slider(value: value, in: range, step: step)
                    .labelsHidden()
                    .frame(minWidth: 120)
                Text(text(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .trailing)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
