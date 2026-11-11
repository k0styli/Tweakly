import AppKit
import SwiftUI
import TaskManagerCore

/// The task manager: every process in one table, apps first, with End Task, Get Info and a search field in the toolbar,
/// as in Activity Monitor. The table is AppKit's, as a SwiftUI table measured twice the memory and three times the
/// processor for the same rows.
struct TaskManagerPageView: View {
    let model: TaskManagerModel
    @Bindable var settings: AppSettings
    let searchRequests: Int
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var model = model
        // Under the toolbar, as Finder's list is, so the toolbar and the column titles share one background.
        ProcessTableHost(controller: model.processes)
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        model.endTask(force: false)
                    } label: {
                        Label("End Task", systemImage: "xmark.octagon")
                    }
                    .help("End the selected task")
                    .disabled(!model.canEnd)
                    Button(action: model.showInfo) {
                        Label("Get Info", systemImage: "info.circle")
                    }
                    .help("Show information about the selected task")
                    .disabled(!model.hasSelection)
                    options
                }
            }
            .searchable(text: $model.query, placement: .toolbar, prompt: Text("Search Processes"))
            .searchFocused($isSearchFocused)
            .onChange(of: searchRequests) { isSearchFocused = true }
            .sheet(isPresented: $model.isShowingShortcut) {
                ShortcutSheet(settings: settings)
            }
    }

    /// What Finder keeps in its action menu: the view's choices, and the rarer setting of the shortcut.
    private var options: some View {
        @Bindable var model = model
        return Menu {
            Section("Columns") {
                ForEach(TaskColumn.allCases.filter(\.canBeHidden), id: \.self) { column in
                    Toggle(
                        column.title,
                        isOn: Binding(get: { model.isShown(column) }, set: { _ in model.toggle(column) }))
                }
                Button("Restore Default Columns", action: model.resetColumns)
            }
            Picker("Update Frequency", selection: $model.interval) {
                ForEach(TaskManagerModel.intervals, id: \.self) { seconds in
                    Text(Self.title(of: seconds)).tag(seconds)
                }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Keyboard Shortcut…") { model.isShowingShortcut = true }
        } label: {
            Label("Options", systemImage: "ellipsis.circle")
        }
        .help("Columns, update frequency and keyboard shortcut")
    }

    private static func title(of seconds: TimeInterval) -> String {
        switch seconds {
        case 1: String(localized: "Every Second")
        case 2: String(localized: "Every 2 Seconds")
        case 5: String(localized: "Every 5 Seconds")
        default: String(localized: "Paused")
        }
    }
}

/// The table, kept by the model so that its sort, open groups and selection survive a visit to another page.
private struct ProcessTableHost: NSViewControllerRepresentable {
    let controller: ProcessesViewController

    func makeNSViewController(context: Context) -> ProcessesViewController { controller }
    func updateNSViewController(_ controller: ProcessesViewController, context: Context) {}
}

/// Whether the task manager opens with a shortcut from any app, and which one.
private struct ShortcutSheet: View {
    @Bindable var settings: AppSettings

    var body: some View {
        DetailsSheet(height: 160) {
            Section {
                Toggle(isOn: $settings.taskManagerEnabled) {
                    Text("Open with a Keyboard Shortcut")
                    Text("Works in any app. ⌥⌘⎋ stays the system’s Force Quit window.")
                }
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: $settings.taskManagerShortcut)
                }
                .disabled(!settings.taskManagerEnabled)
            }
        }
    }
}

/// A shortcut that is set by pressing it, as in Keyboard Shortcuts in System Settings: a button with the shortcut on it,
/// which waits for the keys once pressed. Escape gives up and leaves the shortcut as it was.
private struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: KeyShortcut.Problem?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if shortcut != .standard, !isRecording {
                    Button("Default") {
                        shortcut = .standard
                        problem = nil
                    }
                    .buttonStyle(.link)
                }
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Text(verbatim: isRecording ? String(localized: "Type Shortcut") : shortcut.displayText)
                        .frame(minWidth: 90)
                }
                .accessibilityLabel(Text("Shortcut"))
                .accessibilityValue(Text(verbatim: shortcut.displayText))
            }
            if let problem {
                Text(message(for: problem))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .onDisappear(perform: stop)
    }

    private func message(for problem: KeyShortcut.Problem) -> String {
        switch problem {
        case .needsControlOrOption:
            String(
                localized: "Add Control or Option, so the shortcut does not type a letter or take an app’s own command."
            )
        case .forceQuitWindow: String(localized: "This one opens the system’s Force Quit window.")
        case .takenBySystem: String(localized: "macOS already uses this shortcut.")
        }
    }

    private func start() {
        problem = nil
        isRecording = true
        // The agent lets go of the current shortcut, or pressing it again would open the task manager instead.
        ProcessEvents.post(.shortcutRecording)
        let system = KeyShortcut.systemShortcuts()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let pressed = KeyShortcut(event: event)
            if pressed.keyCode == 53, pressed.modifiers == 0 {
                stop()
                return nil
            }
            if let found = pressed.problem(against: system) {
                problem = found
                return nil
            }
            shortcut = pressed
            stop()
            return nil
        }
    }

    private func stop() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        // Whether or not the shortcut changed, the agent takes it back now.
        ProcessEvents.post(.settingsChanged)
    }
}
