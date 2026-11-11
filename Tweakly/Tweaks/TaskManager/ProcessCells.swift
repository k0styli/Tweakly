import AppKit
import SystemMetrics
import TaskManagerCore

extension TaskColumn {
    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .cpu: String(localized: "taskManager.column.cpu", defaultValue: "CPU")
        case .memory: String(localized: "Memory")
        case .disk: String(localized: "taskManager.column.disk", defaultValue: "Disk")
        case .network: String(localized: "taskManager.column.network", defaultValue: "Network")
        case .gpu: String(localized: "taskManager.column.gpu", defaultValue: "GPU")
        case .pid: String(localized: "PID")
        case .user: String(localized: "User")
        case .kind: String(localized: "taskManager.column.kind", defaultValue: "Kind")
        case .threads: String(localized: "Threads")
        case .cpuTime: String(localized: "CPU Time")
        case .diskRead: String(localized: "Disk Read")
        case .diskWrite: String(localized: "Disk Write")
        case .received: String(localized: "Receiving")
        case .sent: String(localized: "Sending")
        case .architecture: String(localized: "Architecture")
        }
    }

    /// What the header's tooltip says, for the columns whose title alone is not clear.
    var help: String? {
        switch self {
        case .cpu: String(localized: "Share of all the processor’s cores")
        case .memory: String(localized: "Memory the process uses, as Activity Monitor counts it")
        case .disk: String(localized: "Reading and writing together")
        case .network: String(localized: "Receiving and sending together")
        case .gpu: String(localized: "Share of the graphics processor’s time")
        case .cpuTime: String(localized: "Processor time used since the process started")
        default: nil
        }
    }

    /// Narrow enough for the five main columns beside a readable name in the window's first size.
    var width: CGFloat {
        switch self {
        case .name: 220
        case .cpu, .gpu, .pid, .threads: 62
        case .memory: 86
        case .kind: 110
        case .user: 100
        case .cpuTime, .architecture: 96
        case .diskRead, .diskWrite: 112
        default: 80
        }
    }

    var isNumeric: Bool {
        switch self {
        case .name, .user, .kind, .architecture: false
        default: true
        }
    }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
}

/// The text of each cell. Formatters are made once, as cells are filled every second.
enum ProcessText {
    static let unknown = "—"
    /// Windows' way of counting, where 100 % is every core at work, so that the column adds up to the Mac's total.
    static let coreCount = max(SystemInfo.current.coreCount, ProcessInfo.processInfo.activeProcessorCount)
    static let totalMemory = ProcessInfo.processInfo.physicalMemory
    private static let decimalSeparator = Locale.current.decimalSeparator ?? "."

    static func value(
        of column: TaskColumn, _ usage: ProcessUsage, section: ProcessSection, userNames: [UInt32: String]
    )
        -> String?
    {
        switch column {
        case .name: usage.name
        case .cpu: usage.cpu.map { load($0 / Double(coreCount)) }
        case .memory: usage.memory.map(memory)
        case .disk: usage.diskRate.map(Format.rate)
        case .network: usage.networkRate.map(Format.rate)
        case .gpu: usage.gpu.map(load)
        case .pid: String(usage.pid)
        case .user: userNames[usage.userID] ?? String(usage.userID)
        case .kind: kinds[section.rawValue]
        case .threads: usage.threads.map { String($0) }
        case .cpuTime: usage.cpuTime.map(time)
        case .diskRead: usage.diskReadRate.map(Format.rate)
        case .diskWrite: usage.diskWriteRate.map(Format.rate)
        case .received: usage.receiveRate.map(Format.rate)
        case .sent: usage.sendRate.map(Format.rate)
        case .architecture: usage.isTranslated.map { $0 ? "Intel" : "Apple" }
        }
    }

    private static let kinds = ProcessSection.allCases.map { section in
        switch section {
        case .apps: String(localized: "App")
        case .background: String(localized: "Background")
        case .system: String(localized: "taskManager.kind.system", defaultValue: "System")
        }
    }

    /// Shares to a tenth of a percent, each made once: most of a column shows the same few, every second.
    private static var loads = [String?](repeating: nil, count: 1001)

    static func load(_ fraction: Double) -> String {
        let tenths = (fraction * 1000).rounded(.toNearestOrEven)
        guard tenths >= 0, tenths <= 1000 else { return Format.processLoad(fraction) }
        let index = Int(tenths)
        if let known = loads[index] { return known }
        let made = Format.processLoad(Double(index) / 1000)
        loads[index] = made
        return made
    }

    /// An idle process keeps its footprint from one update to the next, so most sizes were already written once.
    private static var memories: [UInt64: String] = [:]

    static func memory(_ bytes: UInt64) -> String {
        if let known = memories[bytes] { return known }
        if memories.count >= 4096 { memories.removeAll(keepingCapacity: true) }
        let made = Format.memorySize(bytes)
        memories[bytes] = made
        return made
    }

    /// Whether a figure is nothing at all, as it is for most processes most of the time.
    static func isZero(_ column: TaskColumn, _ usage: ProcessUsage) -> Bool {
        let value: Double? =
            switch column {
            case .cpu: usage.cpu
            case .gpu: usage.gpu
            case .disk: usage.diskRate
            case .network: usage.networkRate
            case .diskRead: usage.diskReadRate
            case .diskWrite: usage.diskWriteRate
            case .received: usage.receiveRate
            case .sent: usage.sendRate
            default: nil
            }
        // Below what the column can show, which reads as zero there too.
        return value.map { $0 < 0.0005 || (column != .cpu && column != .gpu && $0 < 500) } ?? false
    }

    /// Hours, minutes and seconds to the hundredth, as Activity Monitor writes processor time: `1:02:03.45`.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return unknown }
        let hundredths = Int((seconds * 100).rounded(.down))
        let (hours, minutes) = (hundredths / 360_000, hundredths / 6_000 % 60)
        let (wholeSeconds, fraction) = (hundredths / 100 % 60, hundredths % 100)
        let tail = "\(pad(wholeSeconds))\(decimalSeparator)\(pad(fraction))"
        return hours > 0 ? "\(hours):\(pad(minutes)):\(tail)" : "\(minutes):\(tail)"
    }

    private static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
}

/// A cell of plain text. Laid out by frame rather than constraints: a table refilled every second spent most of its time
/// solving constraints for cells.
///
/// The load columns are shaded as in Windows' Task Manager, in the system's accent colour: faint for an idle figure and
/// stronger as it grows, in a few steps, so a figure that moves a little does not repaint its cell.
final class ProcessTextCell: NSTableCellView {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Room between the text and the cell's edges, which with the gap between columns keeps neighbours apart.
    static let inset: CGFloat = 7

    /// As round as the system's inset rows.
    static let cornerRadius: CGFloat = 6

    private let label = NSTextField(labelWithString: "")
    private var level: Int?
    private var roundedCorners: CACornerMask = []
    /// What the label holds, kept here because asking the label copies its text on every update.
    private var shownText = ""
    private var shownColor: NSColor?
    private var labelHeight: CGFloat?

    /// A selected row is the system's selection colour from end to end, as in Finder, so its figures are not shaded.
    var isRowSelected = false {
        didSet { if isRowSelected != oldValue, level != nil { needsDisplay = true } }
    }

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        wantsLayer = true
        label.font = Self.font
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = roundedCorners.isEmpty ? 0 : Self.cornerRadius
        layer?.maskedCorners = roundedCorners
        guard let level, !isRowSelected else {
            layer?.backgroundColor = nil
            return
        }
        layer?.backgroundColor = ProcessShade.cgColor(level, in: self)
    }

    override func layout() {
        super.layout()
        // One line in one font, so its height never changes.
        let height = labelHeight ?? ceil(label.intrinsicContentSize.height)
        labelHeight = height
        label.frame = NSRect(
            x: Self.inset, y: floor((bounds.height - height) / 2), width: max(bounds.width - Self.inset * 2, 0),
            height: height)
    }

    /// The shaded figures of a section make one block, and only its four outer corners are round.
    func setRoundedCorners(_ corners: CACornerMask) {
        guard corners != roundedCorners else { return }
        roundedCorners = corners
        needsDisplay = true
    }

    /// Nil reads as unknown: a dash in the quietest colour. Nothing at all is quieter than a real figure. `shade` is the
    /// step of colour for a load column, and nil for any other.
    func show(_ text: String?, isZero: Bool = false, shade: Int? = nil) {
        let shown = text ?? ProcessText.unknown
        if shownText != shown {
            shownText = shown
            label.stringValue = shown
        }
        let color: NSColor = text == nil ? .tertiaryLabelColor : isZero ? .secondaryLabelColor : .labelColor
        if shownColor !== color {
            shownColor = color
            label.textColor = color
        }
        if shade != level {
            level = shade
            needsDisplay = true
        }
    }
}

/// The colours of the load columns: the accent colour the person chose in System Settings, blue unless they changed it,
/// faint for an idle figure and stronger with the load. It follows light and dark mode and Increase Contrast.
enum ProcessShade {
    /// The resolved colours for each appearance, as a column of cells asks for the same few steps over and over.
    private static var resolved: [NSAppearance.Name: [CGColor?]] = [:]

    /// Forgets the colours when the accent colour or the contrast changes.
    static func forget() { resolved = [:] }

    static func cgColor(_ level: Int, in view: NSView) -> CGColor {
        let appearance = view.effectiveAppearance
        let step = min(max(level, 0), LoadShade.steps)
        var steps = resolved[appearance.name] ?? [CGColor?](repeating: nil, count: LoadShade.steps + 1)
        if let known = steps[step] { return known }
        let base = view.enclosingScrollView?.backgroundColor ?? .controlBackgroundColor
        var made = NSColor.clear.cgColor
        appearance.performAsCurrentDrawingAppearance { made = color(step, over: base).cgColor }
        steps[step] = made
        resolved[appearance.name] = steps
        return made
    }

    static func color(_ level: Int, over background: NSColor) -> NSColor {
        let fraction = CGFloat(min(max(level, 0), LoadShade.steps)) / CGFloat(LoadShade.steps)
        return mix(0.06 + 0.5 * fraction, over: background)
    }

    private static func mix(_ strength: CGFloat, over background: NSColor) -> NSColor {
        let base = background.usingColorSpace(.deviceRGB) ?? background
        let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .controlAccentColor
        return base.blended(withFraction: strength, of: accent) ?? accent.withAlphaComponent(strength)
    }
}

/// The name, with the app's icon, the triangle that opens a group and the number of processes in it.
final class ProcessNameCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("name")
    private static let triangleWidth: CGFloat = 16
    private static let iconSize: CGFloat = 16
    private static let memberIndent: CGFloat = 20

    let disclosure = NSButton()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var indent: CGFloat = 0
    private var shownName = ""
    private var shownCount = 0

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.setAccessibilityLabel(String(localized: "Show Processes"))
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = ProcessTextCell.font
        label.lineBreakMode = .byTruncatingTail
        addSubview(disclosure)
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
    }

    required init?(coder: NSCoder) { nil }

    /// On the system's selection the name and its count turn white, as the system does for plain text there. The count's
    /// own colour is set by hand, so it is set again here.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard backgroundStyle != oldValue else { return }
            disclosure.contentTintColor = isEmphasized ? .alternateSelectedControlTextColor : nil
            setLabel(name: shownName, count: shownCount)
        }
    }

    private var isEmphasized: Bool { backgroundStyle == .emphasized }

    private func setLabel(name: String, count: Int) {
        let nameColour: NSColor = isEmphasized ? .alternateSelectedControlTextColor : .labelColor
        let countColour: NSColor =
            isEmphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
        let text = NSMutableAttributedString(
            string: name, attributes: [.foregroundColor: nameColour, .font: ProcessTextCell.font])
        if count > 1 {
            // The number of processes, quieter than the name, as Windows shows it.
            text.append(
                NSAttributedString(
                    string: " (\(count))", attributes: [.foregroundColor: countColour, .font: ProcessTextCell.font]))
        }
        label.attributedStringValue = text
    }

    func show(name: String, count: Int, image: NSImage, canOpen: Bool, isOpen: Bool, isMember: Bool) {
        let newIndent = isMember ? Self.memberIndent : 0
        if newIndent != indent {
            indent = newIndent
            needsLayout = true
        }
        disclosure.isHidden = !canOpen
        let state: NSControl.StateValue = isOpen ? .on : .off
        if disclosure.state != state { disclosure.state = state }
        if icon.image !== image { icon.image = image }
        guard name != shownName || count != shownCount else { return }
        shownName = name
        shownCount = count
        setLabel(name: name, count: count)
    }

    override func layout() {
        super.layout()
        let middle = bounds.midY
        let triangle = NSRect(x: indent + 2, y: floor(middle - 8), width: Self.triangleWidth, height: 16)
        disclosure.frame = triangle
        let iconX = triangle.maxX + 2
        icon.frame = NSRect(
            x: iconX, y: floor(middle - Self.iconSize / 2), width: Self.iconSize, height: Self.iconSize)
        let textX = iconX + Self.iconSize + 6
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: textX, y: floor(middle - height / 2), width: max(bounds.width - textX - 2, 0), height: height)
    }
}

/// The title of Apps or Background Processes, in a group row, as Finder's list titles its groups.
///
/// The label is deliberately not the cell's `textField`: the table restyles that field in some group rows and not in
/// others, which left one section's title larger than the next.
final class ProcessSectionCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section")
    private static let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = Self.font
        label.textColor = .secondaryLabelColor
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ text: String) {
        if label.stringValue != text {
            label.stringValue = text
            setAccessibilityLabel(text)
        }
        if label.font != Self.font { label.font = Self.font }
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(
            x: 6, y: floor((bounds.height - height) / 2), width: max(bounds.width - 12, 0), height: height)
    }
}
