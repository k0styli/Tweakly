import AppKit
import SwiftUI
import UninstallerCore

/// Every app with how much it takes and how much it keeps elsewhere, laid out as Applications in System Settings ›
/// Storage, and a sheet that shows each file before it goes. Everything goes to the Trash, never straight away.
///
/// The table is AppKit's, as the task manager's is, see `AppsTableController`; the page around it is SwiftUI.
struct UninstallerPageView: View {
    let model: UninstallerModel
    let isWindowVisible: Bool
    let searchRequests: Int
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var model = model
        // Under the toolbar, as Finder's list is, so the toolbar and the column titles share one background.
        AppsTableHost(controller: model.table)
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        model.begin(.uninstall)
                    } label: {
                        Label("Uninstall…", systemImage: "trash")
                    }
                    .help("Move the selected app and its files to the Trash")
                    .disabled(model.selection == nil)
                    Button {
                        model.begin(.reset)
                    } label: {
                        Label("Reset…", systemImage: "arrow.counterclockwise")
                    }
                    .help("Move the selected app’s data and settings to the Trash, and keep the app")
                    .disabled(model.selection == nil)
                }
            }
            .searchable(text: $model.query, placement: .toolbar, prompt: Text("Search Apps"))
            .searchFocused($isSearchFocused)
            .onChange(of: searchRequests) { isSearchFocused = true }
            .sheet(item: $model.plan) { plan in
                RemovalSheet(plan: plan, model: model)
            }
            .pollingPermissions(
                whileVisible: isWindowVisible && model.needsFullDiskAccess, every: 2, model.refreshFullDiskAccess)
    }
}

/// The table, kept by the model so that its scroll and selection survive a visit to another page.
private struct AppsTableHost: NSViewControllerRepresentable {
    let controller: AppsTableController

    func makeNSViewController(context: Context) -> AppsTableController { controller }
    func updateNSViewController(_ controller: AppsTableController, context: Context) {}
}

/// The sheet's list, made for its plan.
private struct RemovalTableHost: NSViewControllerRepresentable {
    let plan: RemovalPlan

    let model: UninstallerModel

    func makeNSViewController(context: Context) -> RemovalTableController {
        let controller = RemovalTableController(plan: plan)
        #if TWEAKLY_AUTOMATION
            model.sheetTable = controller
        #endif
        return controller
    }
    func updateNSViewController(_ controller: RemovalTableController, context: Context) {}
}

/// What goes, each file with a box to keep it, before anything moves. The same sheet resets an app, without the app.
private struct RemovalSheet: View {
    private static var iconSize: CGFloat { 48 }

    @Bindable var plan: RemovalPlan
    let model: UninstallerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            notes
            if plan.items.isEmpty, plan.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if plan.items.isEmpty {
                ContentUnavailableView(
                    "Nothing to Reset", systemImage: "checkmark.circle",
                    description: plan.otherCopy == nil
                        ? Text("“\(plan.app.name)” keeps no files of its own outside the app.")
                        : Text("Its files are shared with the other copy, so they stay."))
            } else {
                RemovalTableHost(plan: plan, model: model)
            }
            if let problem = plan.problem {
                Label {
                    Text(problem)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .accessibilityHidden(true)
                }
                .font(.subheadline)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Show in Finder") {
                    if let path = plan.selection { reveal(path) }
                }
                .disabled(plan.selection == nil)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(plan.isWorking)
            }
            ToolbarItem(placement: .confirmationAction) {
                HStack(spacing: 8) {
                    if plan.isWorking { ProgressView().controlSize(.small) }
                    Button(plan.mode == .uninstall ? "Move to Trash" : "Reset") { model.carryOut(plan) }
                        .disabled(!plan.canProceed)
                }
            }
        }
        .interactiveDismissDisabled(plan.isWorking)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: model.icon(forApp: plan.app.id))
                .resizable()
                .frame(width: Self.iconSize, height: Self.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                // As the sheets in System Settings › Storage title themselves: the name and what it takes.
                Text(
                    verbatim: plan.items.isEmpty
                        ? plan.app.name : "\(plan.app.name) — \(UninstallerText.size(plan.checkedSize))"
                )
                .font(.headline)
                Text(
                    plan.mode == .uninstall
                        ? "What is ticked goes to the Trash. Until you empty it, all of it can be put back."
                        : "Its data and settings go to the Trash, and the app stays. Next time it opens as if new."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var notes: some View {
        let lines = noteLines
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.text) { line in
                    HStack(spacing: 6) {
                        Label {
                            Text(line.text)
                        } icon: {
                            Image(systemName: line.symbol).accessibilityHidden(true)
                        }
                        if line.offersDiskAccess {
                            Button("Allow…", action: FullDiskAccess.openSettings)
                                .buttonStyle(.link)
                        }
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private struct NoteLine {
        let symbol: String
        let text: String
        var offersDiskAccess = false
    }

    private var noteLines: [NoteLine] {
        var lines: [NoteLine] = []
        let name = plan.app.name
        if plan.isSearching {
            lines.append(NoteLine(symbol: "magnifyingglass", text: String(localized: "Looking for the app’s files…")))
        }
        if plan.isRunning {
            lines.append(
                NoteLine(symbol: "power", text: String(localized: "“\(name)” is open. Tweakly will quit it first.")))
        }
        if plan.needsPassword {
            lines.append(
                NoteLine(
                    symbol: "lock",
                    text: String(
                        localized: "For the items with a lock, macOS will ask for an administrator’s password.")))
        }
        if let copy = plan.otherCopy {
            lines.append(
                NoteLine(
                    symbol: "square.on.square",
                    text: String(
                        localized: "Its data stays, as another copy uses it: \(UninstallerText.shortPath(copy))")))
        }
        if plan.hasUnreadableData {
            lines.append(
                NoteLine(
                    symbol: "lock.shield",
                    text: String(localized: "Containers are measured only with Full Disk Access."),
                    offersDiskAccess: true))
        }
        return lines
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
