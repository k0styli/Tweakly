import AppKit
import CustomIconCore
import SwiftUI
import SystemMetrics
import UniformTypeIdentifiers

/// The simple view: whether the menu bar shows one icon with rings behind it, which metrics get a ring, and what the
/// icon looks like and how it moves. Getting an icon out of a chat is rarer and has a sheet of its own.
struct SimpleViewPageView: View {
    private static let columns = [GridItem(.adaptive(minimum: 84), spacing: 10, alignment: .top)]
    private static let metricColumns = [GridItem(.adaptive(minimum: 160), spacing: 10, alignment: .leading)]
    private static var lookWidth: CGFloat { 84 }
    private static var previewFillLevel: Double { 0.6 }
    /// What a paste can bring: an SVG, the text of a chat's answer, or a picture.
    fileprivate static let pastedTypes: [UTType] = [.svg, .plainText, .image]

    @Bindable var settings: AppSettings
    @State private var icons = IconLibrary.all()
    @State private var isChoosingFile = false
    @State private var isDrawing = false
    @State private var isAdding = false
    @State private var failure: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            Section {
                MainSwitch(
                    symbol: MainPage.simpleView.symbol, title: Text("Simple View"),
                    detail: Text(
                        "One icon in the menu bar instead of one for each metric. Clicking it shows them all together."),
                    isOn: $settings.simpleViewEnabled)
            }
            lookSection
                .disabled(!settings.simpleViewEnabled)
            metricsSection
                .disabled(!settings.simpleViewEnabled)
            iconSection
                .disabled(!settings.simpleViewEnabled)
            if isSelectedAnimated {
                motionSection
                    .disabled(!settings.simpleViewEnabled)
            }
            fillSection
                .disabled(!settings.simpleViewEnabled)
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFile, allowedContentTypes: [.image, .svg]) { result in
            guard case .success(let url) = result else { return }
            add { try IconImporter.add(fileAt: url) }
        }
        .sheet(isPresented: $isDrawing) {
            IconPromptSheet { paste($0) }
        }
    }

    private var selectedIcon: IconManifest? {
        icons.first { $0.id == settings.simpleViewIcon }
    }

    private var isSelectedAnimated: Bool { selectedIcon?.isAnimated == true }

    private var shownMode: IconMotionMode { settings.iconMotion.shownMode(isAnimated: isSelectedAnimated) }

    /// How full the chosen icon looks on this page, where no load is being read.
    private var previewFill: Double? { settings.iconMotion.fills ? Self.previewFillLevel : nil }

    /// The label on the left and the pictures on the right of one row, as Appearance has them in System Settings.
    private var lookSection: some View {
        Section {
            LabeledContent {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(SimpleViewLook.allCases) { look in
                        LookChoice(title: look.title, isSelected: settings.simpleViewLook == look) {
                            settings.simpleViewLook = look
                        } preview: {
                            SimpleLookPreview(look: look)
                        }
                        .frame(width: Self.lookWidth)
                    }
                }
                // A row's value is grey by default, and these captions should match the icons' further down the page.
                .foregroundStyle(.primary)
            } label: {
                Text("How to Show")
                Text(
                    "Rings give one figure per metric, a list the main parts of each. A right click on the icon also switches."
                )
            }
        }
    }

    /// Check boxes, as for the items of the menu bar in System Settings. Six switches would fill the first screen.
    private var metricsSection: some View {
        Section {
            LazyVGrid(columns: Self.metricColumns, alignment: .leading, spacing: 8) {
                ForEach(MetricKind.available) { kind in
                    Toggle(isOn: isShown(kind)) {
                        Label {
                            Text(kind.title)
                        } icon: {
                            // One width for every symbol, the battery's wide one included, so the names line up in
                            // their columns.
                            Image(systemName: kind.symbol)
                                .frame(width: 24)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, 2)
        } header: {
            SectionTitle(
                title: Text("What to Show"),
                detail: Text("Metrics left out keep their own icons, if they have them turned on."))
        }
    }

    private func isShown(_ kind: MetricKind) -> Binding<Bool> {
        Binding(
            get: { settings.simpleViewMetrics.contains(kind) },
            set: { isOn in
                if isOn {
                    settings.simpleViewMetrics.insert(kind)
                } else {
                    settings.simpleViewMetrics.remove(kind)
                }
            }
        )
    }

    // MARK: The icon

    private var iconSection: some View {
        Section {
            LazyVGrid(columns: Self.columns, spacing: 12) {
                gearChoice
                ForEach(icons) { icon in
                    iconChoice(icon)
                }
            }
            .padding(.vertical, 4)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                add { try IconImporter.add(fileAt: url) }
                return true
            }
            if selectedIcon?.hasColours == true {
                Toggle(isOn: $settings.simpleViewIconOwnColours) {
                    Text("Keep the Icon's Colors")
                    Text("Otherwise it takes the menu bar's one color, as the system's icons do.")
                }
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
            }
            HStack {
                if isAdding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Draw with AI…") { isDrawing = true }
                PasteButton(supportedContentTypes: Self.pastedTypes) { paste($0) }
                Button("Add from File…") { isChoosingFile = true }
            }
        } header: {
            Text("Icon")
        } footer: {
            Text(
                "SVG, GIF, PNG, WebP or JPEG. A file can also be dropped here. Its size and margins are adjusted to suit the menu bar. Control-click an icon you added to delete it."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var gearChoice: some View {
        LookChoice(title: String(localized: "Gear"), isSelected: settings.simpleViewIcon == nil, keepsToOneLine: true) {
            settings.simpleViewIcon = nil
        } preview: {
            if settings.simpleViewIcon == nil, let previewFill, let gear = LoadedIcon.gear {
                IconPreview(icon: gear.manifest, usesOwnColours: false, speed: nil, fill: previewFill)
                    .frame(
                        width: CGFloat(gear.manifest.frameWidth) / CGFloat(IconFit.pixelsPerPoint),
                        height: CGFloat(gear.manifest.frameHeight) / CGFloat(IconFit.pixelsPerPoint))
            } else {
                Image("MenuBarIcon")
                    .renderingMode(.template)
            }
        }
    }

    private func iconChoice(_ icon: IconManifest) -> some View {
        let isSelected = icon.id == settings.simpleViewIcon
        return LookChoice(title: icon.name, isSelected: isSelected, keepsToOneLine: true) {
            guard !isSelected else { return }
            settings.simpleViewIconOwnColours = icon.hasColours
            settings.simpleViewIcon = icon.id
        } preview: {
            IconPreview(
                icon: icon, usesOwnColours: isSelected ? settings.simpleViewIconOwnColours : icon.hasColours,
                speed: isSelected ? previewSpeed : nil, fill: isSelected ? previewFill : nil
            )
            .frame(
                width: CGFloat(icon.frameWidth) / CGFloat(IconFit.pixelsPerPoint),
                height: CGFloat(icon.frameHeight) / CGFloat(IconFit.pixelsPerPoint))
        }
        .contextMenu {
            if !IconLibrary.isBuiltIn(id: icon.id) {
                Button("Delete Icon", role: .destructive) { delete(icon) }
            }
        }
    }

    /// Only the chosen icon moves, and as it will in the menu bar. One that follows the load shows its middle speed.
    private var previewSpeed: Double? {
        guard !reduceMotion else { return nil }
        let motion = settings.iconMotion
        switch shownMode {
        case .still: return nil
        case .loop: return motion.loopSpeed
        case .load: return motion.speed(atLoad: 0.5)
        }
    }

    private func delete(_ icon: IconManifest) {
        if settings.simpleViewIcon == icon.id { settings.simpleViewIcon = nil }
        IconLibrary.delete(id: icon.id)
        icons = IconLibrary.all()
    }

    private func paste(_ providers: [NSItemProvider]) {
        guard let provider = providers.first,
            let type = Self.pastedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }),
            let identifier = provider.registeredTypeIdentifiers.first(where: { registered in
                UTType(registered)?.conforms(to: type) == true
            })
        else {
            failure = IconFileError.unreadable.message
            return
        }
        let name = String(localized: "Pasted Icon")
        let isText = type == .plainText
        _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
            Task { @MainActor in
                guard let data else {
                    failure = IconFileError.unreadable.message
                    return
                }
                add {
                    if isText { return try IconImporter.add(text: String(decoding: data, as: UTF8.self), name: name) }
                    return try IconImporter.add(data: data, name: name)
                }
            }
        }
    }

    /// Off the main thread, so that a slow file leaves the window alive. The new icon becomes the chosen one, since
    /// that is why someone adds one.
    private func add(_ work: @escaping @Sendable () throws -> IconManifest) {
        isAdding = true
        failure = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result(catching: work)
            }.value
            isAdding = false
            switch result {
            case .success(let icon):
                icons = IconLibrary.all()
                settings.simpleViewIconOwnColours = icon.hasColours
                settings.simpleViewIcon = icon.id
            case .failure(let error):
                failure = (error as? IconFileError)?.message ?? IconFileError.unreadable.message
            }
        }
    }

    // MARK: Movement

    private var motionSection: some View {
        Section {
            Picker(selection: $settings.iconMotion.mode) {
                ForEach(IconMotionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                Text("Icon Mode")
                if settings.iconMotion.mode != .still {
                    if reduceMotion {
                        Text("Reduce Motion is on in System Settings, so the icon stands still.")
                    } else {
                        Text("An icon nobody can see stands still and costs nothing. Low Power Mode halves its speed.")
                    }
                }
            }
            switch settings.iconMotion.mode {
            case .still:
                EmptyView()
            case .loop:
                speedRow("Speed", value: $settings.iconMotion.loopSpeed)
            case .load:
                Picker("Follows", selection: $settings.iconMotion.source) {
                    ForEach(IconLoadSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                speedRow("Speed at Rest", value: $settings.iconMotion.idleSpeed)
                speedRow("Speed at Full Load", value: $settings.iconMotion.busySpeed)
            }
        }
    }

    /// A choice of its own, because it goes with any icon and any movement.
    private var fillSection: some View {
        Section {
            Toggle(isOn: $settings.iconMotion.fills) {
                Text("Fill with the Load")
                Text("It stays dim and fills from the bottom up as the load grows.")
            }
            if settings.iconMotion.fills {
                Picker("Follows", selection: $settings.iconMotion.fillSource) {
                    ForEach(IconLoadSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
            }
        }
    }

    private func speedRow(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: IconMotion.speeds, step: 0.25)
                    .labelsHidden()
                Text("×" + value.wrappedValue.formatted(.number.precision(.fractionLength(0...2))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// A custom icon drawn by the same code as the one in the menu bar.
private struct IconPreview: NSViewRepresentable {
    let icon: IconManifest
    let usesOwnColours: Bool
    /// Nil stands still.
    let speed: Double?
    /// Nil shows the whole icon.
    let fill: Double?

    func makeNSView(context: Context) -> CustomIconView {
        let view = CustomIconView(frame: .zero)
        show(in: view)
        return view
    }

    func updateNSView(_ view: CustomIconView, context: Context) {
        if view.shownIcon?.manifest.id != icon.id || view.usesOwnColours != showsOwnColours {
            show(in: view)
        } else {
            updateSpeed(of: view)
        }
    }

    private var showsOwnColours: Bool { usesOwnColours && icon.hasColours }

    private func show(in view: CustomIconView) {
        guard let loaded = icon.id == LoadedIcon.gearID ? LoadedIcon.gear : IconLibrary.load(id: icon.id) else {
            return
        }
        view.show(loaded, usesOwnColours: showsOwnColours)
        updateSpeed(of: view)
    }

    private func updateSpeed(of view: CustomIconView) {
        view.setFill(fill, animated: false)
        if let speed {
            view.play(speed: speed)
        } else {
            view.stop()
        }
    }
}

/// A small picture of each look, made of the same marks as the popover: rings with an accent arc, bars on a neutral track.
private struct SimpleLookPreview: View {
    private static let fractions = [0.7, 0.4, 0.85]

    let look: SimpleViewLook

    var body: some View {
        switch look {
        case .rings:
            HStack(spacing: 5) {
                ForEach(Self.fractions, id: \.self) { fraction in
                    ZStack {
                        Circle().stroke(.quaternary, lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: fraction)
                            .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)
                }
            }
        case .list:
            VStack(spacing: 5) {
                ForEach(Self.fractions, id: \.self) { fraction in
                    GeometryReader { size in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(.tint).frame(width: size.size.width * fraction)
                        }
                    }
                    .frame(width: 58, height: 4)
                }
            }
        }
    }
}

/// Gets an icon out of ChatGPT, Claude or the like: says what to draw, copies the brief, and the answer comes back by
/// Paste. Rare, and it takes three steps in order, so it stays off the page until asked for.
private struct IconPromptSheet: View {
    private static let services = [("ChatGPT", "https://chatgpt.com"), ("Claude", "https://claude.ai")]
    /// Long enough to read, and short enough not to look stuck.
    private static let copiedSeconds = 2
    private static var height: CGFloat { 320 }

    let paste: ([NSItemProvider]) -> Void
    @State private var subject = ""
    @State private var isAnimated = true
    @State private var isColoured = false
    @State private var wasCopied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DetailsSheet(height: Self.height) {
            Section {
                TextField("What to Draw", text: $subject, prompt: Text("a running cat"))
                LabeledContent("Kind") {
                    Picker("Kind", selection: $isAnimated) {
                        Text("Animated").tag(true)
                        Text("Still").tag(false)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }
                Toggle("In Color", isOn: $isColoured)
            } header: {
                SectionTitle(
                    title: Text("Draw an Icon with AI"),
                    detail: Text("The prompt knows the sizes, the frames and the style an icon needs here."))
            }
            Section {
                LabeledContent("1. Copy the prompt") {
                    Button(wasCopied ? String(localized: "Copied") : String(localized: "Copy Prompt"), action: copy)
                        .disabled(subject.allSatisfy(\.isWhitespace))
                }
                LabeledContent("2. Paste it into a chat") {
                    HStack(spacing: 12) {
                        ForEach(Self.services, id: \.0) { name, address in
                            if let url = URL(string: address) {
                                Link(name, destination: url)
                            }
                        }
                    }
                }
                LabeledContent("3. Copy the SVG from the answer") {
                    PasteButton(supportedContentTypes: SimpleViewPageView.pastedTypes) { providers in
                        paste(providers)
                        dismiss()
                    }
                }
            }
        }
    }

    private func copy() {
        let prompt = IconPrompt.make(description: subject, isAnimated: isAnimated, isColoured: isColoured)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        wasCopied = true
        Task {
            try? await Task.sleep(for: .seconds(Self.copiedSeconds))
            wasCopied = false
        }
    }
}

extension IconFileError {
    var message: String {
        switch self {
        case .tooLarge: String(localized: "This file is too large for an icon.")
        case .unreadable: String(localized: "This does not look like a picture. SVG, GIF, PNG, WebP and JPEG will do.")
        case .empty: String(localized: "There is nothing to show in this file: it is empty or fully transparent.")
        }
    }
}

extension IconMotionMode {
    var title: String {
        switch self {
        case .still: String(localized: "Still")
        case .loop: String(localized: "In a Loop")
        case .load: String(localized: "Speed with the Load")
        }
    }
}

extension IconLoadSource {
    var title: String {
        switch self {
        case .cpu: MetricKind.cpu.title
        case .gpu: MetricKind.gpu.title
        case .memory: MetricKind.memory.title
        case .busiest: String(localized: "Whichever Is Busier: Processor or Graphics")
        }
    }
}
