import AppKit
import LiveWallpaperCore
import Observation
import SwiftUI
import WebKit
import os

/// The downloads of one browser window, for its toolbar and the list behind its downloads button.
@Observable final class BrowserDownloads {
    enum State: Equatable {
        case downloading
        case adding
        case added
        case refused(String)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        var name: String
        var state: State
        var received: Int64 = 0
        /// Zero while the site has not said how large the file is.
        var expected: Int64 = 0
        /// The wallpaper it became, once in the library.
        var libraryID: String?

        var fraction: Double? {
            expected > 0 ? min(1, Double(received) / Double(expected)) : nil
        }

        var isRunning: Bool { state == .downloading || state == .adding }
    }

    private(set) var items: [Item] = []
    /// Whether the page shown is one a wallpaper in the library came from.
    var isPageInLibrary = false
    /// The download that went into the library last, until the next page opens.
    var justAdded: UUID?

    var isBusy: Bool { items.contains(where: \.isRunning) }

    /// Whether the toolbar has anything to say.
    var hasStatus: Bool { isBusy || justAdded != nil || isPageInLibrary }

    /// The download the toolbar talks about: the one running, if any.
    var running: Item? { items.first(where: \.isRunning) }

    /// Between 0 and 1 over every download running whose size is known.
    var progress: Double? {
        let known = items.filter { $0.state == .downloading }.compactMap(\.fraction)
        guard !known.isEmpty else { return isBusy ? 0 : nil }
        return known.reduce(0, +) / Double(known.count)
    }

    func start(_ name: String) -> UUID {
        let item = Item(name: name, state: .downloading)
        items.insert(item, at: 0)
        return item.id
    }

    func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    func clearFinished() {
        items.removeAll { !$0.isRunning }
        justAdded = nil
    }
}

/// A browser window for the wallpaper sites. People find a wallpaper themselves and download it under the site's own
/// terms; whatever is a video or a picture goes into the library, and anything else is refused. It runs in the window
/// process and is released when closed, which ends the system's web processes for it too.
///
/// What happens to a download shows in three places, as in Safari: the downloads button turns into its progress, the
/// list behind it opens by itself when a download starts, and the middle of the toolbar says what is going on, or that
/// the page's wallpaper is in the library already.
final class WallpaperBrowserController: NSObject, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate,
    WKUIDelegate, WKDownloadDelegate
{
    private static let frameName = "TweaklyWallpaperBrowser"
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")
    private static let navigationItem = NSToolbarItem.Identifier("navigation")
    private static let reloadItem = NSToolbarItem.Identifier("reload")
    private static let sitesItem = NSToolbarItem.Identifier("sites")
    private static let statusItem = NSToolbarItem.Identifier("status")
    private static let libraryItem = NSToolbarItem.Identifier("library")
    private static let downloadsItem = NSToolbarItem.Identifier("downloads")
    private static let popUnderWindow: TimeInterval = 3

    let downloads = BrowserDownloads()
    private let library: WallpaperLibraryModel
    private let window: NSWindow
    private var webView: WKWebView?
    private let onIdle: () -> Void
    private var observations: [NSKeyValueObservation] = []
    /// Each download's progress and size limit, kept until it ends: a download goes on after the window closes, and
    /// must keep its 4 GB limit there.
    private var downloadObservations: [ObjectIdentifier: [NSKeyValueObservation]] = [:]
    /// What the page was when each download began, to name it in the library.
    private var contexts: [ObjectIdentifier: (item: UUID, title: String?, page: URL?, file: URL?)] = [:]
    private var pendingContext: (title: String?, page: URL?)?
    /// Until when a script sending the page to another site counts as the advertisement of a pop-under.
    private var popUnderUntil = Date.distantPast
    private weak var navigationControl: NSSegmentedControl?
    private weak var sitesItemView: NSMenuToolbarItem?
    private weak var statusItemView: NSToolbarItem?
    private weak var downloadsButtonItem: NSToolbarItem?
    private var downloadsPopover: NSPopover?
    private var isClosed = false

    var isBusy: Bool { !isClosed || downloads.isBusy }

    #if TWEAKLY_AUTOMATION
        /// Every decision about a navigation, for tests to see where a site's button led.
        private(set) var navigationLog: [String] = []

        func close() { window.close() }

        func runScript(_ script: String) {
            webView?.evaluateJavaScript(script) { _, error in
                if let error { NSLog("browser script: %@", error.localizedDescription) }
            }
        }
    #endif

    private func note(_ line: String) {
        #if TWEAKLY_AUTOMATION
            navigationLog.append(line)
        #endif
    }

    init(library: WallpaperLibraryModel, onIdle: @escaping () -> Void) {
        self.library = library
        self.onIdle = onIdle
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        super.init()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.toolbarStyle = .unified
        window.title = String(localized: "Wallpapers on the Web")
        window.delegate = self
        let toolbar = NSToolbar(identifier: "WallpaperBrowser")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
        window.setFrameUsingName(Self.frameName)
        window.setFrameAutosaveName(Self.frameName)
    }

    func show(_ address: URL) {
        let webView = self.webView ?? makeWebView()
        isClosed = false
        webView.load(URLRequest(url: address))
        #if TWEAKLY_AUTOMATION
            if QuietScreen.isActive { QuietScreen.place(window) }
        #endif
        window.makeKeyAndOrderFront(nil)
        if QuietScreen.mayActivate { NSApp.activate() }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // As Safari: a warning before a known fraudulent page, and HTTPS wherever the site is known to have it.
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.upgradeKnownHostsToHTTPS = true
        // Sites treat an unknown browser as a robot; this is what Safari on this Mac says.
        configuration.applicationNameForUserAgent = "Version/\(Self.safariVersion) Safari/605.1.15"
        let webView = WKWebView(frame: window.contentLayoutRect, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        window.contentView = webView
        observations = [
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.webStateChanged() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.webStateChanged() },
            webView.observe(\.title) { [weak self] _, _ in self?.webStateChanged() },
            webView.observe(\.url) { [weak self] _, _ in self?.webStateChanged() },
        ]
        self.webView = webView
        return webView
    }

    private static let safariVersion: String = {
        let info = Bundle(path: "/Applications/Safari.app")?.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "26.0"
    }()

    private nonisolated func webStateChanged() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateChrome() }
        }
    }

    private func updateChrome() {
        guard let webView else { return }
        navigationControl?.setEnabled(webView.canGoBack, forSegment: 0)
        navigationControl?.setEnabled(webView.canGoForward, forSegment: 1)
        let title = webView.title ?? ""
        window.title = title.isEmpty ? String(localized: "Wallpapers on the Web") : title
        window.subtitle = DownloadNaming.site(of: webView.url) ?? ""
        let site = WallpaperSite.builtIn.first {
            DownloadRule.registrableDomain(of: $0.address) == webView.url.flatMap(DownloadRule.registrableDomain(of:))
        }
        sitesItemView?.title = site?.name ?? String(localized: "Sites")
        let page = webView.backForwardList.currentItem?.url
        downloads.isPageInLibrary = page.map(library.isInLibrary(page:)) ?? false
        refreshStatus()
    }

    /// Shown only while it has something to say, which changes with these events and nothing else.
    private func refreshStatus() {
        statusItemView?.isHidden = !downloads.hasStatus
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        downloadsPopover?.close()
        // The page goes, and with it the site's processes; downloads under way carry on to the library.
        observations = []
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
        window.contentView = nil
        isClosed = true
        finishIfIdle()
    }

    private func finishIfIdle() {
        guard isClosed, !downloads.isBusy else { return }
        onIdle()
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.navigationItem, Self.reloadItem, Self.sitesItem, .flexibleSpace, Self.statusItem, .flexibleSpace,
            Self.libraryItem, Self.downloadsItem,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.navigationItem:
            let images = ["chevron.left", "chevron.right"].compactMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier, images: images, selectionMode: .momentary,
                labels: [String(localized: "Back"), String(localized: "Forward")], target: self,
                action: #selector(navigate(_:)))
            group.controlRepresentation = .expanded
            group.subitems.first?.toolTip = String(localized: "Back")
            group.subitems.last?.toolTip = String(localized: "Forward")
            navigationControl = group.view as? NSSegmentedControl
            return group
        case Self.reloadItem:
            return button(
                identifier, symbol: "arrow.clockwise", label: String(localized: "Reload"),
                tip: String(localized: "Reload the page"), action: #selector(reload))
        case Self.sitesItem:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Sites")
            item.title = String(localized: "Sites")
            item.showsIndicator = true
            item.menu = sitesMenu()
            sitesItemView = item
            return item
        case Self.statusItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = NSHostingView(rootView: BrowserStatus(downloads: downloads))
            item.label = String(localized: "Status")
            item.visibilityPriority = .low
            // Nothing to say is no reason for an empty field in the middle of the toolbar.
            item.isHidden = true
            statusItemView = item
            return item
        case Self.libraryItem:
            return button(
                identifier, symbol: "photo.on.rectangle", label: String(localized: "Library"),
                tip: String(localized: "Show the library of Live Wallpaper"), action: #selector(showLibrary))
        case Self.downloadsItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let host = NSHostingView(
                rootView: DownloadsButton(downloads: downloads) { [weak self] in self?.toggleDownloads() })
            item.view = host
            item.label = String(localized: "Downloads")
            item.toolTip = String(localized: "Show downloads")
            item.visibilityPriority = .high
            downloadsButtonItem = item
            return item
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, symbol: String, label: String, tip: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.label = label
        item.toolTip = tip
        item.target = self
        item.action = action
        return item
    }

    private func sitesMenu() -> NSMenu {
        let menu = NSMenu()
        for site in WallpaperSite.builtIn {
            let item = NSMenuItem(title: site.name, action: #selector(openSite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = site.address
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let other = NSMenuItem(
            title: String(localized: "Other Address…"), action: #selector(askAddress), keyEquivalent: "l")
        other.target = self
        menu.addItem(other)
        return menu
    }

    @objc private func navigate(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { webView?.goBack() } else { webView?.goForward() }
    }

    @objc private func reload() {
        webView?.reload()
    }

    @objc private func showLibrary() {
        library.onShowLibrary?()
    }

    @objc private func openSite(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? URL else { return }
        webView?.load(URLRequest(url: address))
    }

    /// As in Safari, an address without `https://` works.
    @objc private func askAddress() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Open a Site")
        alert.informativeText = String(localized: "Type the address of a site with wallpapers.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let url = WallpaperSite.url(fromTyped: field.stringValue)
                else { return }
                self?.webView?.load(URLRequest(url: url))
            }
        }
    }

    private func toggleDownloads() {
        if let downloadsPopover, downloadsPopover.isShown {
            downloadsPopover.close()
        } else {
            showDownloads()
        }
    }

    /// As Safari does, the list opens by itself when a download starts.
    private func showDownloads() {
        guard let item = downloadsButtonItem, item.toolbar != nil, window.isVisible else { return }
        if let downloadsPopover, downloadsPopover.isShown { return }
        let content = NSHostingController(
            rootView: DownloadsList(
                downloads: downloads, library: library,
                choose: { [weak self] id in self?.library.chooseForDesktop(id) },
                showLibrary: { [weak self] in
                    self?.downloadsPopover?.close()
                    self?.library.onShowLibrary?()
                }))
        // The popover takes the list's size before it opens and follows it as rows come and go. Left to itself it
        // opened at its default 320 by 320, and the list then resized the window from its lower corner, which put it
        // 177 points below the button (measured 2026-11-08).
        content.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.contentSize = content.view.fittingSize
        // The item rather than its view, so that the list also opens when the button is in the overflow menu.
        popover.show(relativeTo: item)
        downloadsPopover = popover
    }

    // MARK: Navigation

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // Links into other apps, such as the App Store, stay closed: this window is for web pages.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        note(
            "action \(navigationAction.request.url?.absoluteString ?? "") main=\(navigationAction.targetFrame?.isMainFrame ?? false)"
        )
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else { return (.cancel, preferences) }
        if let target = navigationAction.request.url,
            DownloadRule.blocksRedirect(
                to: target, from: webView.backForwardList.currentItem?.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                isLinkClick: navigationAction.navigationType == .linkActivated, afterPopUnder: Date.now < popUnderUntil)
        {
            note("redirect refused \(target.absoluteString)")
            return (.cancel, preferences)
        }
        if navigationAction.shouldPerformDownload {
            pendingContext = (webView.title, webView.backForwardList.currentItem?.url ?? webView.url)
            return (.download, preferences)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async
        -> WKNavigationResponsePolicy
    {
        let response = navigationResponse.response
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        note("response \(response.url?.absoluteString ?? "") \(response.mimeType ?? "") \(disposition ?? "")")
        guard
            DownloadRule.shouldDownload(
                isMainFrame: navigationResponse.isForMainFrame, mimeType: response.mimeType,
                contentDisposition: disposition, canShow: navigationResponse.canShowMIMEType)
        else { return .allow }
        pendingContext = (webView.title, webView.backForwardList.currentItem?.url ?? webView.url)
        return .download
    }

    /// A new page clears what the toolbar said about the last download.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        downloads.justAdded = nil
        updateChrome()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        adopt(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download)
    }

    /// A page asking for a new window gets it in this one if it stays on its site or leads to a file. Advertisements
    /// that open on a click elsewhere go nowhere.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let page = webView.backForwardList.currentItem?.url
        if let target = navigationAction.request.url, DownloadRule.isPopUnder(target, on: page) {
            // Already here; what follows is the advertisement.
            popUnderUntil = Date.now.addingTimeInterval(Self.popUnderWindow)
            note("pop-under refused \(target.absoluteString)")
        } else if let target = navigationAction.request.url, DownloadRule.opensInPlace(target, from: page) {
            note("new window in place \(target.absoluteString)")
            webView.load(navigationAction.request)
        } else {
            note("new window refused \(navigationAction.request.url?.absoluteString ?? "")")
        }
        return nil
    }

    // MARK: Downloads

    private func adopt(_ download: WKDownload) {
        download.delegate = self
        let context = pendingContext
        pendingContext = nil
        let item = downloads.start(String(localized: "Download"))
        contexts[ObjectIdentifier(download)] = (item, context?.title, context?.page, nil)
        showDownloads()
        refreshStatus()
        // Whole percents only: the progress changes with every packet, and the toolbar needs far fewer updates.
        let reporter = ProgressReporter { [weak self, weak download] _ in
            guard let progress = download?.progress else { return }
            self?.downloads.update(item) {
                $0.received = progress.completedUnitCount
                $0.expected = max(0, progress.totalUnitCount)
            }
        }
        // A site that sends no size, or a wrong one, is stopped once it passes the limit. Checked in whole percents of
        // the limit, not with every packet.
        let limit = ProgressReporter { [weak self, weak download] _ in
            guard let download, download.progress.completedUnitCount > MediaInbox.largestFile else { return }
            self?.refuseTooLarge(download)
        }
        downloadObservations[ObjectIdentifier(download)] = [
            download.progress.observe(\.fractionCompleted) { progress, _ in
                reporter.report(progress.fractionCompleted)
            },
            download.progress.observe(\.completedUnitCount) { progress, _ in
                limit.report(min(1, Double(progress.completedUnitCount) / Double(MediaInbox.largestFile + 1)))
            },
        ]
    }

    /// The download is over, one way or another, and nothing of it needs watching.
    private func forget(_ download: WKDownload) -> (item: UUID, title: String?, page: URL?, file: URL?)? {
        let id = ObjectIdentifier(download)
        downloadObservations[id] = nil
        return contexts.removeValue(forKey: id)
    }

    private func refuseTooLarge(_ download: WKDownload) {
        guard let context = forget(download) else { return }
        download.cancel { _ in }
        if let file = context.file { try? FileManager.default.removeItem(at: file) }
        downloads.update(context.item) {
            $0.state = .refused(String(localized: "Larger than 4 GB, so not downloaded."))
        }
        refreshStatus()
        finishIfIdle()
    }

    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        let id = ObjectIdentifier(download)
        guard var context = contexts[id] else { return nil }
        // What the site calls it only decides whether to bother: what it is, the cleaner tells from its bytes.
        guard DownloadRule.kind(mimeType: response.mimeType, fileName: suggestedFilename) != nil else {
            downloads.update(context.item) {
                $0.state = .refused(String(localized: "Not a video or picture, so not added."))
                $0.name = suggestedFilename
            }
            _ = forget(download)
            refreshStatus()
            finishIfIdle()
            return nil
        }
        guard response.expectedContentLength <= MediaInbox.largestFile else {
            downloads.update(context.item) {
                $0.state = .refused(String(localized: "Larger than 4 GB, so not downloaded."))
                $0.name = suggestedFilename
            }
            _ = forget(download)
            refreshStatus()
            finishIfIdle()
            return nil
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WallpaperDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A name of our own with an extension no app opens: the site's name never becomes a path or a file type.
        let file = folder.appendingPathComponent(UUID().uuidString + ".download")
        context.file = file
        contexts[id] = context
        let title = DownloadNaming.title(
            pageTitle: context.title, fileName: suggestedFilename,
            site: DownloadNaming.site(of: context.page ?? download.originalRequest?.url))
        downloads.update(context.item) {
            $0.name = title
            $0.expected = max(0, response.expectedContentLength)
        }
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let context = forget(download), let file = context.file else { return }
        Self.markDownloaded(file, from: download.originalRequest?.url, page: context.page)
        downloads.update(context.item) { $0.state = .adding }
        let title = downloads.items.first { $0.id == context.item }?.name ?? file.lastPathComponent
        let site = DownloadNaming.site(of: context.page ?? download.originalRequest?.url)
        let source = WallpaperImporter.Source(origin: .downloaded, title: title, site: site, pageURL: context.page)
        Task {
            do {
                let entry = try await WallpaperImporter.addDownload(at: file, from: source)
                library.add(entry)
                downloads.update(context.item) {
                    $0.state = .added
                    $0.libraryID = entry.wallpaper.id
                    $0.received = entry.byteCount
                }
                downloads.justAdded = context.item
                updateChrome()
            } catch {
                try? FileManager.default.removeItem(at: file)
                downloads.update(context.item) {
                    $0.state = .failed(WallpaperLibraryModel.describe(error, file: title))
                }
            }
            refreshStatus()
            finishIfIdle()
        }
    }

    /// As Safari marks a download: should the raw file ever be found and opened, the system knows where it came from
    /// and checks it as it would anything from the internet.
    private static func markDownloaded(_ file: URL, from source: URL?, page: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Tweakly",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var marked = file
        try? marked.setResourceValues(values)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let context = forget(download) else { return }
        if let file = context.file { try? FileManager.default.removeItem(at: file) }
        Self.log.error("Download failed: \(error.localizedDescription, privacy: .public)")
        downloads.update(context.item) { $0.state = .failed(error.localizedDescription) }
        refreshStatus()
        finishIfIdle()
    }
}

/// The middle of the toolbar: what the download under way is doing, that one just went into the library, or that
/// the wallpaper on this page is there already. Empty otherwise.
private struct BrowserStatus: View {
    let downloads: BrowserDownloads

    // An image and a text rather than a label: a label in a toolbar shows its icon alone.
    var body: some View {
        HStack(spacing: 6) {
            if let running = downloads.running {
                Image(systemName: "arrow.down.circle")
                Text(running.state == .adding ? addingText(running) : downloadingText(running))
            } else if let added = downloads.justAdded.flatMap({ id in downloads.items.first { $0.id == id } }) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("“\(added.name)” is in the library")
            } else if downloads.isPageInLibrary {
                Image(systemName: "checkmark.circle")
                Text("This wallpaper is in the library already")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: 340)
        .accessibilityElement(children: .combine)
    }

    private func addingText(_ item: BrowserDownloads.Item) -> String {
        String(localized: "Adding “\(item.name)” to the library…")
    }

    private func downloadingText(_ item: BrowserDownloads.Item) -> String {
        guard let fraction = item.fraction else { return String(localized: "Downloading “\(item.name)”…") }
        return String(localized: "Downloading “\(item.name)”: \(Int(fraction * 100))%")
    }
}

/// The downloads button, which shows how far the downloads are while they run, as Safari's does.
private struct DownloadsButton: View {
    let downloads: BrowserDownloads
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let progress = downloads.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "arrow.down.circle")
                    .frame(width: 18, height: 18)
            }
        }
        .accessibilityLabel(Text("Downloads"))
    }
}

/// The list behind the downloads button: each file with a picture of it once added, how far it is, and what can be
/// done with it.
private struct DownloadsList: View {
    let downloads: BrowserDownloads
    let library: WallpaperLibraryModel
    let choose: (String) -> Void
    let showLibrary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .controlSize(.small)
                    .disabled(downloads.items.allSatisfy(\.isRunning))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if downloads.items.isEmpty {
                Text("Download a video or picture on the site, and it goes into the library of Live Wallpaper.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(downloads.items) { item in
                            row(item)
                            if item.id != downloads.items.last?.id { Divider().padding(.leading, 14) }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("Show Library", action: showLibrary)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 380)
    }

    private func row(_ item: BrowserDownloads.Item) -> some View {
        HStack(alignment: .center, spacing: 10) {
            DownloadThumbnail(entry: item.libraryID.flatMap(library.entry), library: library)
                .frame(width: 64, height: 40)
                .clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status(item)
            }
            Spacer(minLength: 4)
            if item.state == .added, let id = item.libraryID, library.entry(id) != nil {
                Button("Set as Wallpaper") { choose(id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func status(_ item: BrowserDownloads.Item) -> some View {
        switch item.state {
        case .downloading:
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: item.fraction ?? 0)
                    .controlSize(.small)
                Text(sizes(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .adding:
            Text("Adding to the library…").font(.caption).foregroundStyle(.secondary)
        case .added:
            if let id = item.libraryID, let fraction = library.optimizing[id] {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                    Text("In the library. Making it lighter to play: \(Int(fraction * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label {
                    Text(addedText(item))
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        case .refused(let reason), .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .lineLimit(2)
        }
    }

    private func sizes(_ item: BrowserDownloads.Item) -> String {
        let received = Format.fileSize(UInt64(max(item.received, 0)))
        guard item.expected > 0 else { return received }
        let expected = Format.fileSize(UInt64(item.expected))
        return String(localized: "\(received) of \(expected)")
    }

    private func addedText(_ item: BrowserDownloads.Item) -> String {
        guard let id = item.libraryID, let entry = library.entry(id) else {
            return String(localized: "In the library")
        }
        let size = Format.fileSize(UInt64(max(entry.byteCount, 0)))
        return String(localized: "In the library · \(size)")
    }
}

/// A download's picture, once it has one in the library.
private struct DownloadThumbnail: View {
    let entry: LibraryIndex.Entry?
    let library: WallpaperLibraryModel
    @State private var image: NSImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: entry?.wallpaper.kind == .picture ? "photo" : "film")
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: entry?.wallpaper.id) {
                guard let entry else { return }
                image = await library.thumbnails.load(entry)
            }
            .accessibilityHidden(true)
    }
}
