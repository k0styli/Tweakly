import AppKit
import FanControlCore
import Observation
import ServiceManagement
import SystemMetrics
import notify

/// Everything Tweakly asks macOS for, as the window sees it: the Permissions page shows all of it, and the page of each
/// feature reads from here what that feature is waiting for.
///
/// Nothing here runs on a timer. It reads when a page that shows it appears, when the window's app becomes active
/// again (which is how someone comes back from System Settings), when macOS announces that a permission changed, and
/// after its own actions. It lives in the window's process, which exits with the window, so it costs the agent
/// nothing; the agent checks what a tweak needs at the moment the tweak acts.
@Observable final class SystemAccess {
    /// A permission macOS keeps in Privacy & Security, as far as this process can tell without asking for it.
    enum Grant: Equatable {
        case allowed
        case notAllowed
        /// macOS asks the first time a feature needs it.
        case askedOnFirstUse
    }

    enum Helper: Equatable {
        case notInstalled
        /// Installed, and its version is being asked.
        case checking
        /// Older than this copy of the app, or signed by another one, so it does not answer everything asked.
        case outdated
        case installed
    }

    /// Assumed given until the first reading, so a page that opens does not flash a warning.
    private(set) var accessibility = true
    private(set) var screenRecording = true
    /// Screen Recording arrived while this window was open. Pictures need Tweakly to start again, as System Settings
    /// itself says when the switch is turned on.
    private(set) var screenRecordingArrived = false
    private(set) var audioRecording = Grant.askedOnFirstUse
    private(set) var fullDiskAccess = true
    private(set) var filesAndFolders = Grant.askedOnFirstUse
    private(set) var finderExtension = true
    private(set) var loginItem = SMAppService.Status.notRegistered
    private(set) var helper = Helper.notInstalled
    /// What the last change of the login item said, when it failed.
    private(set) var loginItemError: String?

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var accessibilityChanges: AccessibilityChanges?
    @ObservationIgnored private var tokens: [Int32] = []
    @ObservationIgnored private var helperClient: FanHelperClient?
    @ObservationIgnored private var hasRead = false
    /// Screen Recording takes 12 to 37 ms to ask, so it is asked off the main thread, one question at a time.
    @ObservationIgnored private var isReadingScreenRecording = false
    @ObservationIgnored private var readsScreenRecordingAgain = false
    /// A feature that needs both was turned on without Accessibility: Screen Recording is asked once that arrives, as
    /// macOS shows one request at a time.
    @ObservationIgnored private var asksScreenRecordingNext = false
    /// The agent turns the Finder extension on a moment after the switch, so until then off only means on its way.
    @ObservationIgnored private var finderExtensionExpectedUntil = Date.distantPast

    init() {
        // Coming back from System Settings makes this app active again.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        accessibilityChanges = AccessibilityChanges { [weak self] in self?.refresh() }
        // tccd announces every change of a privacy permission, of any app, under this name. It is rare, and only
        // heard while the window is open.
        var token: Int32 = NOTIFY_TOKEN_INVALID
        if notify_register_dispatch(
            "com.apple.tcc.access.changed", &token, .main,
            { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }) == NOTIFY_STATUS_OK
        {
            tokens.append(token)
        }
        // The process that plays apps' sound says when it was refused.
        tokens.append(ProcessEvents.observe(.volumeMixerStateChanged) { [weak self] in self?.refresh() })
        refresh()
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        tokens.forEach { notify_cancel($0) }
        helperClient?.close()
    }

    /// Reads everything again. The helper is asked only when the Permissions page shows it, as asking starts it.
    func refresh(includingHelper: Bool = false) {
        #if TWEAKLY_AUTOMATION
            if let given = UserDefaults.standard.string(forKey: "accessDemo") {
                demo(given)
                return
            }
            // A test copy showing made-up data draws every page as it looks with everything given.
            if DemoData.isOn {
                demo("accessibility,screenRecording,audio,disk,folders,extension,login,helper")
                return
            }
        #endif
        let hadAccessibility = accessibility
        accessibility = AXIsProcessTrusted()
        audioRecording = Self.audioRecording
        fullDiskAccess = FullDiskAccess.isGranted
        filesAndFolders = Self.filesAndFolders
        let extensionOn = FinderExtension.isEnabled
        finderExtension = extensionOn || Date.now < finderExtensionExpectedUntil
        loginItem = SMAppService.mainApp.status
        if hasRead, accessibility != hadAccessibility {
            // The agent hears this itself, but a page that changed it may as well say so at once.
            ProcessEvents.post(.settingsChanged)
            if accessibility, asksScreenRecordingNext {
                asksScreenRecordingNext = false
                if !CGPreflightScreenCaptureAccess() { SystemPermission.screenRecording.ask() }
            }
        }
        readScreenRecording()
        if includingHelper { readHelper() }
    }

    /// System Audio Recording, told exactly where the private question exists, and otherwise only once a tap of the
    /// process that plays has been refused.
    private static var audioRecording: Grant {
        switch PrivacyPreflight.answer(for: .audioCapture) {
        case .allowed: .allowed
        case .denied: .notAllowed
        case .notAsked: .askedOnFirstUse
        case nil: AudioRuleStore.isPermitted ? .askedOnFirstUse : .notAllowed
        }
    }

    /// The desktop, Documents and Downloads, where New File asks for a folder of its own: refused for any of them reads
    /// as not allowed, as New File fails there.
    private static var filesAndFolders: Grant {
        let answers = [PrivacyPreflight.Service.desktopFolder, .documentsFolder, .downloadsFolder].map {
            PrivacyPreflight.answer(for: $0)
        }
        if answers.contains(.denied) { return .notAllowed }
        return answers.allSatisfy { $0 == .allowed } ? .allowed : .askedOnFirstUse
    }

    private func readScreenRecording() {
        guard !isReadingScreenRecording else {
            readsScreenRecordingAgain = true
            return
        }
        isReadingScreenRecording = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let allowed = CGPreflightScreenCaptureAccess()
            await self?.screenRecordingRead(allowed)
        }
    }

    private func screenRecordingRead(_ allowed: Bool) {
        isReadingScreenRecording = false
        if allowed != screenRecording {
            if hasRead, allowed { screenRecordingArrived = true }
            screenRecording = allowed
            // The agent's window pictures start or stop with this, and it has no event of its own for it.
            if hasRead { ProcessEvents.post(.settingsChanged) }
        }
        hasRead = true
        if readsScreenRecordingAgain {
            readsScreenRecordingAgain = false
            readScreenRecording()
        }
    }

    private func readHelper() {
        guard FanHelperClient.isInstalled else {
            helper = .notInstalled
            return
        }
        if helper == .notInstalled { helper = .checking }
        let client = helperClient ?? FanHelperClient()
        helperClient = client
        client.version { [weak self] version in
            // A newer helper, left by a newer copy of the app, answers everything this one asks. One that does not
            // answer at all is most likely signed differently from this copy, which installing it again puts right.
            self?.helper = (version.map { $0 >= FanHelper.currentVersion } ?? false) ? .installed : .outdated
            client.close()
        }
    }

    // MARK: Actions

    /// A feature that needs these was just turned on. macOS shows one request at a time, so this asks for the first one
    /// missing, and for Screen Recording once Accessibility arrives.
    func askOnTurningOn(accessibility needsAccessibility: Bool = true, screenRecording needsScreenRecording: Bool) {
        if needsAccessibility, !AXIsProcessTrusted() {
            asksScreenRecordingNext = needsScreenRecording
            SystemPermission.accessibility.ask()
        } else if needsScreenRecording, !CGPreflightScreenCaptureAccess() {
            SystemPermission.screenRecording.ask()
        }
    }

    /// Finder Menu was just turned on, and the agent is turning its extension on.
    func expectFinderExtension() {
        finderExtensionExpectedUntil = .now.addingTimeInterval(Self.finderExtensionStartTime)
        finderExtension = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finderExtensionStartTime) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private static var finderExtensionStartTime: TimeInterval { 3 }

    func turnOnFinderExtension() {
        expectFinderExtension()
        FinderExtension.setEnabled(true) { [weak self] _ in self?.refresh() }
    }

    func setOpenAtLogin(_ isOn: Bool) {
        do {
            if isOn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        loginItem = SMAppService.mainApp.status
    }

    /// Nil when it went well or someone pressed Cancel, otherwise what went wrong.
    func installHelper() -> String? {
        let error = FanHelperInstaller.install(
            prompt: String(localized: "Tweakly needs to install a helper with administrator rights."))
        refresh(includingHelper: true)
        return error
    }

    #if TWEAKLY_AUTOMATION
        /// A picture of the page in a chosen state: the names of what counts as given, as a test copy has nothing.
        private func demo(_ given: String) {
            let names = Set(given.split(separator: ",").map(String.init))
            accessibility = names.contains("accessibility")
            screenRecording = names.contains("screenRecording")
            audioRecording =
                names.contains("audio") ? .allowed : names.contains("audioRefused") ? .notAllowed : .askedOnFirstUse
            fullDiskAccess = names.contains("disk")
            filesAndFolders = names.contains("folders") ? .allowed : .askedOnFirstUse
            finderExtension = names.contains("extension")
            loginItem = names.contains("login") ? .enabled : .notRegistered
            helper = names.contains("helper") ? .installed : names.contains("oldHelper") ? .outdated : .notInstalled
            hasRead = true
        }
    #endif
}
