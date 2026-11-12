import AppKit
import SwiftUI

/// The app's window. Its process behaves like a normal app, with a Dock icon and menus, and exits
/// when the window closes. See `WindowProcess` for why.
final class MainWindowController: NSObject, NSWindowDelegate {
    private static let frameName = "TweaklyWindow"
    private static let defaultSize = NSSize(width: 860, height: 660)
    /// The pages were checked down to 470 points beside the sidebar.
    private static let minimumSize = NSSize(width: 741, height: 500)

    private let window: NSWindow
    private let router = MainRouter()
    let keyboardCleaning = KeyboardCleaningController()
    private let feed: OverviewFeed
    let taskManager = TaskManagerModel()
    let uninstaller = UninstallerModel()
    let wallpapers = WallpaperLibraryModel()
    private let access = SystemAccess()
    private let onClose: () -> Void
    /// Every way the window comes back goes through `show`, so the process knows it is open again.
    var onShow: (() -> Void)?
    private var hasFocusedSidebar = false

    init(settings: AppSettings, feed: OverviewFeed, onClose: @escaping () -> Void) {
        self.feed = feed
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        let host = NSHostingController(
            rootView: MainView(
                router: router, settings: settings, data: feed.data, cleaning: keyboardCleaning,
                taskManager: taskManager, uninstaller: uninstaller, wallpapers: wallpapers, access: access))
        host.sceneBridgingOptions = [.title, .toolbars]
        // The window's size belongs to the person using it, not to the size of the current page.
        host.sizingOptions = []
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.toolbarStyle = .unified
        window.delegate = self
        window.setContentSize(Self.defaultSize)
        window.center()
        window.setFrameUsingName(Self.frameName)
        window.setFrameAutosaveName(Self.frameName)
        router.onVisibilityNeeded = { [weak self] in self?.updateOverviewDemand() }
    }

    func show(page: MainPage?) {
        onShow?()
        if let page { router.open(page) }
        #if TWEAKLY_AUTOMATION
            // A quiet test copy stays out of the Dock and Command-Tab, where the person using the Mac would see it.
            NSApp.setActivationPolicy(QuietScreen.isActive ? .accessory : .regular)
            if QuietScreen.isActive { QuietScreen.place(window) }
        #else
            NSApp.setActivationPolicy(.regular)
        #endif
        // A test copy opening during a run must not take the keyboard from whoever is typing elsewhere.
        if QuietScreen.mayActivate { NSApp.activate() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        // The person just asked for this window, even if the system declines to activate a background app.
        window.orderFrontRegardless()
        updateOverviewDemand()
        focusSidebarOnce()
    }

    /// Left alone, a new window gives the keyboard to its first control, the search field. That rings the field
    /// and greys out the selected page. The sidebar is where the keyboard belongs, as the arrow keys then work.
    private func focusSidebarOnce() {
        // The task manager's table takes the keyboard whenever it is asked for, so its shortcuts work at once.
        if router.page == .taskManager {
            hasFocusedSidebar = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.taskManager.focusTable() }
            }
            return
        }
        guard !hasFocusedSidebar else { return }
        hasFocusedSidebar = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let list = Self.firstTable(in: self.window.contentView) else { return }
                self.window.makeFirstResponder(list)
            }
        }
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = firstTable(in: child) { return table }
        }
        return nil
    }

    /// The task manager on its own, the whole window for its columns, as Activity Monitor has: what its shortcut and
    /// the menu bar's Open Task Manager ask for. The sidebar comes back with its button.
    func showTaskManager() {
        router.sidebarVisibility = .detailOnly
        show(page: .taskManager)
    }

    /// The window as Tweakly's settings, which are found through the sidebar, on a page if one is asked for.
    func showWindow(page: MainPage? = nil) {
        router.sidebarVisibility = .all
        show(page: page)
    }

    @objc fileprivate func toggleSidebar() {
        withAnimation { router.sidebarVisibility = router.isSidebarHidden ? .all : .detailOnly }
    }

    @objc fileprivate func showAbout() {
        show(page: .about)
    }

    /// Once, on first opening the window as settings: not over the task manager or the mixer, opened for themselves.
    func offerWelcome() {
        guard Welcome.isDue else { return }
        showWelcome()
    }

    /// Help › Welcome to Tweakly, from its start.
    @objc fileprivate func showWelcome() {
        router.welcomeStep = .features
        if !window.isVisible { showWindow() }
        router.windowContentHeight = window.contentLayoutRect.height
        router.isWelcomeShown = true
    }

    /// A sheet is no taller than the window under its toolbar, so the welcome scrolls in a short window.
    func windowDidResize(_ notification: Notification) {
        guard router.isWelcomeShown else { return }
        router.windowContentHeight = window.contentLayoutRect.height
    }

    @objc fileprivate func showSettings() {
        show(page: .settings)
    }

    /// The page's own field on the pages that have one, and the sidebar's elsewhere.
    @objc fileprivate func focusSearch() {
        if [.taskManager, .uninstaller, .liveWallpaper].contains(router.page) {
            router.toolbarSearchRequests += 1
        } else if router.isSidebarHidden {
            // The field is in the sidebar, which has to be there before it can take the keyboard.
            withAnimation { router.sidebarVisibility = .all }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.sidebarRevealDelay) { [weak self] in
                MainActor.assumeIsolated { self?.router.searchRequests += 1 }
            }
        } else {
            router.searchRequests += 1
        }
    }

    /// Long enough for the sidebar's field to be on screen after the sidebar is asked back.
    private static let sidebarRevealDelay: TimeInterval = 0.3

    /// Quitting from the window means quitting Tweakly, not just closing its window.
    @objc fileprivate func quit() {
        ProcessEvents.quitEverything()
    }

    #if TWEAKLY_AUTOMATION
        func closeWindow() {
            window.close()
        }

        /// The welcome at one of its steps, for a picture of it.
        func showWelcomeForTesting(step: WelcomeStep) {
            router.welcomeStep = step
            router.windowContentHeight = window.contentLayoutRect.height
            router.isWelcomeShown = true
        }

        func closeWelcomeForTesting() {
            router.isWelcomeShown = false
        }

        func search(for text: String) {
            router.query = text
        }

        func resize(width: CGFloat, height: CGFloat) {
            window.setContentSize(NSSize(width: width, height: height))
        }

        func bringToFrontForMeasuring() {
            window.level = .floating
            window.orderFrontRegardless()
        }

        /// Changes the page without activating the app, so a measurement does not take the keyboard away.
        func openPageForMeasuring(_ page: MainPage) {
            router.open(page)
        }

        /// Leaves a corner of the window on screen, which still counts as visible, out of the person's way.
        /// What the pages go by, and what the system says, which should agree.
        var visibilityForTesting: String {
            "router \(router.isWindowVisible) window \(window.occlusionState.contains(.visible)) frame \(window.frame)"
                + " sidebar \(router.isSidebarHidden ? "hidden" : "shown") page \(router.page.id)\n"
        }

        /// What the View menu's item does, and the title it would show now.
        func toggleSidebarForTesting() -> String {
            toggleSidebar()
            let item = NSMenuItem(title: "", action: #selector(toggleSidebar), keyEquivalent: "")
            _ = validateMenuItem(item)
            return item.title
        }

        func moveForMeasuring(x: CGFloat, y: CGFloat) {
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        /// Takes the window off the screen, process and all left running, so a panel of its own can be pictured with
        /// nothing of the window behind its glass.
        func hideForTesting() {
            window.orderOut(nil)
        }

        /// Scrolls the page to this many points from its top, for a picture of what lies further down.
        func scrollForTesting(to points: CGFloat) {
            guard let content = window.contentView else { return }
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            // The page's own scroll view is the largest in the window; the sidebar's list is narrower.
            guard
                let page = scrollViews(in: content).max(by: {
                    $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
                }),
                let document = page.documentView
            else { return }
            let y = document.isFlipped ? points : document.frame.height - page.contentView.bounds.height - points
            page.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            page.reflectScrolledClipView(page.contentView)
        }
    #endif

    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateOverviewDemand()
    }

    func windowWillClose(_ notification: Notification) {
        feed.setVisible(false)
        taskManager.setVisible(false)
        uninstaller.setVisible(false)
        // The pages' permission checks stop with it, while the process may stay on for a download.
        router.isWindowVisible = false
        onClose()
    }

    /// Live values are only sampled while the Home page can actually be seen.
    private func updateOverviewDemand() {
        let isVisible = window.occlusionState.contains(.visible)
        router.isWindowVisible = isVisible
        feed.setVisible(isVisible && router.page == .home)
        let showsTaskManager = isVisible && router.page == .taskManager
        taskManager.setVisible(showsTaskManager)
        uninstaller.setVisible(isVisible && router.page == .uninstaller)
    }
}

/// The menu bar menus shown while the window is open, so the standard shortcuts work.
enum AppMenu {
    static func make(target: MainWindowController) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(
            withTitle: String(localized: "About Tweakly"), action: #selector(MainWindowController.showAbout),
            keyEquivalent: ""
        ).target = target
        app.addItem(.separator())
        app.addItem(
            withTitle: String(localized: "Settings…"), action: #selector(MainWindowController.showSettings),
            keyEquivalent: ","
        ).target = target
        app.addItem(.separator())
        app.addItem(
            withTitle: String(localized: "Hide Tweakly"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(
            withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        ).keyEquivalentModifierMask = [.command, .option]
        app.addItem(
            withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(
            withTitle: String(localized: "Quit Tweakly"), action: #selector(MainWindowController.quit),
            keyEquivalent: "q"
        ).target = target
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)

        // Text fields answer these through the responder chain, and copying a value is a normal thing to want.
        let edit = NSMenu(title: String(localized: "Edit"))
        // A search field's typing is undone as in any app, and the shortcuts reach it only through these items.
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(
            withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(
            withTitle: String(localized: "Search"), action: #selector(MainWindowController.focusSearch),
            keyEquivalent: "f"
        ).target = target
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        // The system's wording and shortcut, as in Finder; the title follows the sidebar, see `validateMenuItem`.
        let view = NSMenu(title: String(localized: "View"))
        let sidebar = view.addItem(
            withTitle: String(localized: "Hide Sidebar"), action: #selector(MainWindowController.toggleSidebar),
            keyEquivalent: "s")
        sidebar.keyEquivalentModifierMask = [.control, .command]
        sidebar.target = target
        let viewItem = NSMenuItem()
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(
            withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        window.addItem(
            withTitle: String(localized: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(
            withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window

        // Where Apple's own apps put their welcome, Freeform's for one, so it can be found again after the first time.
        let helpItem = NSMenuItem()
        let help = NSMenu(title: String(localized: "Help"))
        help.addItem(
            withTitle: String(localized: "Welcome to Tweakly"), action: #selector(MainWindowController.showWelcome),
            keyEquivalent: ""
        ).target = target
        helpItem.submenu = help
        main.addItem(helpItem)
        NSApp.helpMenu = help

        return main
    }
}

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSidebar) {
            menuItem.title =
                router.isSidebarHidden ? String(localized: "Show Sidebar") : String(localized: "Hide Sidebar")
        }
        return true
    }
}
