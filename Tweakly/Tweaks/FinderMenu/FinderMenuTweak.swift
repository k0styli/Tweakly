import AppKit
import FinderMenuCore
import Security
import os

/// Why the Finder menu turned itself off, for its page to say.
enum FinderMenuStopReason: String, Codable {
    /// The way this agent takes a name the extension can find is gone from macOS.
    case unavailable
    /// The extension in the app is missing or its signature does not check out, so nothing could be trusted as it.
    case extensionDamaged
    /// Another process kept the name, such as a copy of Tweakly that would not quit.
    case nameTaken
}

/// New File, Copy Path and Open in Terminal in Finder's shortcut menu.
///
/// The menu itself is a Finder Sync extension, which is sandboxed: it copies paths itself and passes the rest here.
/// While the tweak is on this holds a Mach port the extension finds by name, and nothing else: no timer, observer or
/// thread, as the port's queue wakes only for a message.
final class FinderMenuTweak {
    nonisolated private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "finder-menu")
    private static let terminalID = "com.apple.Terminal"
    /// An agent being replaced holds the name until it has quit, which takes up to a few seconds.
    private static let registerAttempts = 30
    private static let registerRetryDelay: TimeInterval = 0.2

    var onStopped: ((FinderMenuStopReason) -> Void)?
    private var server: FinderMenuServer?
    private var items: FinderMenuItems = []
    private var retry: DispatchWorkItem?
    private var requirement: SecRequirement?
    /// Counts checks of the extension, so one that ends after the tweak went off, or after a newer one began, is dropped.
    private var check = 0
    private var isChecking = false
    private var failureAlert: FailureAlert?

    #if TWEAKLY_AUTOMATION
        private(set) var lastAction = "none"
    #endif

    func update(items: FinderMenuItems) {
        self.items = items
        server?.setItems(items)
        if server == nil, retry == nil, !isChecking { start(attemptsLeft: Self.registerAttempts) }
    }

    /// Leaves nothing behind: the name goes with the port.
    func stop() {
        retry?.cancel()
        retry = nil
        check += 1
        isChecking = false
        server?.stop()
        server = nil
        failureAlert?.close()
        failureAlert = nil
    }

    private func start(attemptsLeft: Int) {
        retry = nil
        guard let requirement else {
            checkExtension(thenStartWith: attemptsLeft)
            return
        }
        let serviceName = FinderMenuWire.serviceName(forApp: Bundle.main.bundleIdentifier ?? "me.tweakly.Tweakly")
        do {
            let server = try FinderMenuServer(serviceName: serviceName, requirement: requirement) {
                [weak self] request in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(request) } }
            }
            server.setItems(items)
            self.server = server
        } catch .nameTaken where attemptsLeft > 1 {
            let work = DispatchWorkItem { [weak self] in self?.start(attemptsLeft: attemptsLeft - 1) }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.registerRetryDelay, execute: work)
        } catch .nameTaken {
            fail(.nameTaken)
        } catch {
            Self.log.error(
                "Could not register for the Finder extension: \(String(describing: error), privacy: .public)")
            fail(.unavailable)
        }
    }

    private func fail(_ reason: FinderMenuStopReason) {
        Self.log.error("The Finder menu stops: \(reason.rawValue, privacy: .public)")
        stop()
        // After the caller is done with this object, as it is about to be released.
        DispatchQueue.main.async { [onStopped] in onStopped?(reason) }
    }

    /// Checking the extension's signature walks its certificate chain, which for Developer ID may ask Apple whether the
    /// certificate was revoked: on the main thread that held the agent up at launch. So it runs on a task of its own,
    /// and only the requirement's text, plain data, comes back. Making the requirement from text checks nothing.
    private func checkExtension(thenStartWith attemptsLeft: Int) {
        check += 1
        let current = check
        isChecking = true
        Task.detached(priority: .utility) { [weak self] in
            let text = Self.extensionRequirementText()
            await MainActor.run {
                guard let self, self.isChecking, self.check == current else { return }
                self.isChecking = false
                var requirement: SecRequirement?
                guard let text, SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                    let requirement
                else {
                    self.fail(.extensionDamaged)
                    return
                }
                self.requirement = requirement
                self.start(attemptsLeft: attemptsLeft)
            }
        }
    }

    /// The designated requirement of the extension inside this app, which is what a sender has to satisfy. With
    /// Developer ID that is its identifier and the team; with the local certificate, its identifier and the certificate;
    /// for an ad-hoc build, its exact code.
    nonisolated private static func extensionRequirementText() -> String? {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return nil }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard
            SecStaticCodeCreateWithPath(
                plugIns.appending(path: "TweaklyFinderMenu.appex") as CFURL, [], &code) == errSecSuccess,
            let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess,
            SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
            SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text
        else {
            log.error("The Finder extension inside the app is missing or its signature does not check out")
            return nil
        }
        return text as String
    }

    private func handle(_ request: FinderMenuRequest) {
        switch request {
        case .items:
            break
        case .newFile(let folder, let name):
            guard items.contains(.newFile) else { return }
            NewFileMaker.make(name, in: folder) { [weak self] result in
                switch result {
                case .success(let file):
                    self?.note("created \(file.lastPathComponent)")
                    FinderRename.start(for: file)
                case .failure(let error):
                    self?.note("failed \(error.code.rawValue)")
                    self?.showFailure(error, folder: folder)
                }
            }
        case .openInTerminal(let path):
            guard items.contains(.openInTerminal) else { return }
            openTerminal(at: path)
        }
    }

    private func openTerminal(at path: String) {
        // Off the main thread: a folder on a network volume that stopped answering would hold the menu bar up.
        Task { [weak self] in
            let kind = await Task.detached(priority: .userInitiated) { Self.kind(at: path) }.value
            guard let self else { return }
            guard let kind else {
                note("terminal: no such item")
                return
            }
            openTerminal(at: path, kind: kind)
        }
    }

    private nonisolated static func kind(at path: String) -> FinderItemKind? {
        guard let values = try? URL(filePath: path).resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
            return nil
        }
        return values.isPackage == true ? .package : values.isDirectory == true ? .folder : .file
    }

    private func openTerminal(at path: String, kind: FinderItemKind) {
        let folder = URL(filePath: TerminalTarget.folder(for: path, kind: kind), directoryHint: .isDirectory)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.terminalID) else {
            note("terminal: not installed")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        note("terminal \(folder.path(percentEncoded: false))")
        // Terminal opens a new window in a folder it is handed, as when one is dropped on its icon.
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: configuration) { _, error in
            if let error {
                Self.log.error("Terminal did not open: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showFailure(_ error: POSIXError, folder: String) {
        failureAlert?.close()
        let alert = FailureAlert(error: error, folder: folder) { [weak self] in self?.failureAlert = nil }
        failureAlert = alert
        alert.show()
    }

    private func note(_ action: String) {
        #if TWEAKLY_AUTOMATION
            lastAction = action
        #endif
    }

    #if TWEAKLY_AUTOMATION
        /// Runs a request as if it came from the extension, to check what follows without Finder.
        func perform(_ request: FinderMenuRequest) {
            handle(request)
        }

        var isListening: Bool { server != nil }
    #endif
}

/// Finder says in an alert when it cannot make a folder somewhere, and so does this. A real `NSAlert`, shown as a
/// window rather than run modally, so the agent's menu bar items go on updating while it is up.
private final class FailureAlert: NSObject {
    private static let privacySettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")

    private let alert = NSAlert()
    private let onClose: () -> Void

    init(error: POSIXError, folder: String, onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
        alert.messageText = String(localized: "The File Could Not Be Created")
        let ok = alert.addButton(withTitle: String(localized: "OK"))
        ok.target = self
        ok.action = #selector(close)
        // What the system refuses for Desktop, Documents and Downloads until it is allowed.
        if error.code == .EPERM || error.code == .EACCES {
            let name = FileManager.default.displayName(atPath: folder)
            alert.informativeText = String(
                localized:
                    "Tweakly has no access to “\(name)”. You can allow it in Privacy & Security, Files & Folders.")
            let open = alert.addButton(withTitle: String(localized: "Open Privacy & Security"))
            open.target = self
            open.action = #selector(openSettings)
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.layout()
        alert.window.appearance = AppSettings.savedTheme.appearance
    }

    func show() {
        if QuietScreen.mayActivate { NSApp.activate() }
        alert.window.center()
        #if TWEAKLY_AUTOMATION
            // A test copy keeps it on its own display, out of sight.
            QuietScreen.place(alert.window)
        #endif
        alert.window.makeKeyAndOrderFront(nil)
    }

    @objc func close() {
        alert.window.orderOut(nil)
        onClose()
    }

    @objc private func openSettings() {
        if let url = Self.privacySettings { NSWorkspace.shared.open(url) }
        close()
    }
}
