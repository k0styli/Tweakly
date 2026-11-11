import AppKit
import Observation
import SystemMetrics
import TaskManagerCore

/// The task manager page: its table, which keeps its sort, open groups and selection for as long as the window is open,
/// and the reading of every process, which runs only while the page can be seen. The window's process exits when the
/// window closes, so all of it costs nothing once the window is gone.
@Observable final class TaskManagerModel {
    private enum Key {
        static let interval = "taskManagerInterval"
    }

    /// Paces Activity Monitor offers, and a pause, as Windows has.
    static let intervals: [TimeInterval] = [1, 2, 5, 0]

    @ObservationIgnored let processes = ProcessesViewController()
    @ObservationIgnored private let feed = ProcessFeed()
    @ObservationIgnored private var engine: MetricsEngine?
    @ObservationIgnored private var cpu: CPUSnapshot?
    @ObservationIgnored private var memory: MemorySnapshot?

    /// For the toolbar's buttons, which SwiftUI draws.
    private(set) var canEnd = false
    private(set) var hasSelection = false
    private(set) var shownColumns: [TaskColumn] = []
    /// The sheet with the keyboard shortcut, from the options menu.
    var isShowingShortcut = false
    var query = "" {
        didSet { processes.query = query }
    }
    var interval: TimeInterval {
        didSet {
            feed.interval = interval
            UserDefaults.standard.set(interval, forKey: Key.interval)
        }
    }

    init() {
        let saved = UserDefaults.standard.object(forKey: Key.interval) as? Double
        interval = saved.flatMap { Self.intervals.contains($0) ? $0 : nil } ?? 1
        feed.interval = interval
        feed.onUpdate = { [weak self] snapshot in self?.processes.apply(snapshot) }
        processes.onDemandChange = { [weak self] demand in
            guard let self else { return }
            feed.demand = demand
            shownColumns = processes.visibleColumns
        }
        processes.onSelectionChange = { [weak self] in self?.selectionChanged() }
        processes.onEnded = { [weak self] in self?.feed.refreshSoon() }
        processes.onInstallHelper = { [weak self] in self?.offerHelper() }
    }

    /// What the helper does, said before the system asks for the password, which only says that a helper is coming.
    func offerHelper() {
        guard let window = processes.viewIfLoaded?.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Show the figures of system processes?")
        alert.informativeText = String(
            localized:
                "About a third of the processes belong to macOS and other users, and only an administrator can read them. Tweakly will install a small helper for this, the one that controls fans on Macs that have them. It runs only while Tweakly asks it something, reads only figures, and ends a process only when you confirm it. macOS will ask for an administrator’s password once."
        )
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            // After the sheet has gone, as the system's own request for the password comes next.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let prompt = String(
                        localized: "Tweakly needs to install a helper to show and end system processes.")
                    if let error = FanHelperInstaller.install(prompt: prompt) {
                        let failure = NSAlert()
                        failure.messageText = String(localized: "The helper could not be installed.")
                        failure.informativeText = error
                        failure.beginSheetModal(for: window)
                    }
                    self?.feed.restart()
                }
            }
        }
    }

    /// Reads only while the page is on screen and the window can be seen.
    func setVisible(_ isVisible: Bool) {
        guard isVisible != feed.isRunning else { return }
        guard isVisible else {
            feed.stop()
            engine = nil
            return
        }
        shownColumns = processes.visibleColumns
        feed.demand = processes.demand
        feed.start()
        let engine = MetricsEngine { [weak self] updates in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(updates) }
            }
        }
        // The whole processor and memory for the line under the table, which no sum of processes gives without root.
        engine.apply(SamplingPlan(levels: [.cpu: .overview, .memory: .overview]))
        self.engine = engine
    }

    private func received(_ updates: [MetricUpdate]) {
        guard engine != nil else { return }
        for update in updates {
            switch update {
            case .cpu(let snapshot): cpu = snapshot
            case .memory(let snapshot): memory = snapshot
            default: break
            }
        }
        var parts: [String] = []
        if let cpu { parts.append(String(localized: "CPU \(Format.percent(cpu.usage))")) }
        if let memory, memory.total > 0 {
            let used = Format.memorySize(memory.used)
            let total = Format.memorySize(memory.usable > 0 ? memory.usable : memory.total)
            parts.append(String(localized: "Memory \(used) of \(total)"))
        }
        processes.totals = parts.joined(separator: "   ")
    }

    private func selectionChanged() {
        hasSelection = processes.selectedUsage != nil
        canEnd = processes.hasTarget
    }

    func endTask(force: Bool) { processes.endTarget(force: force) }
    func showInfo() { processes.toggleInfo() }
    func isShown(_ column: TaskColumn) -> Bool { shownColumns.contains(column) }
    func toggle(_ column: TaskColumn) { processes.toggle(column) }
    func resetColumns() { processes.resetColumns() }

    /// The keyboard goes to the table when the page opens, so the arrows and the shortcuts work at once.
    func focusTable() {
        guard let window = processes.viewIfLoaded?.window else { return }
        window.makeFirstResponder(processes.tableForFocus)
    }
}
