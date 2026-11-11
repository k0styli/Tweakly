import AppKit
import TaskManagerCore

/// The apps the system knows to be running, which is what groups form around.
///
/// Asking the system for every app's name, bundle and kind took 15 ms on each update, so the answers are kept and read
/// anew only when the list of apps changes, or when an app comes to the front, the moment an agent that opened a window
/// would have become a regular app.
final class RunningApps {
    private var cache: [Int32: AppIdentity] = [:]
    private var isStale = true
    private var listObservation: NSKeyValueObservation?
    private var activation: NSObjectProtocol?

    init() {
        let workspace = NSWorkspace.shared
        listObservation = workspace.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.isStale = true }
            }
        }
        activation = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let pid, self.cache[pid]?.isRegular == false else { return }
                self.isStale = true
            }
        }
    }

    isolated deinit {
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    }

    /// Read on the main thread, where the system keeps this list up to date.
    func identities() -> [Int32: AppIdentity] {
        guard isStale else { return cache }
        isStale = false
        var identities: [Int32: AppIdentity] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            identities[pid] = AppIdentity(
                pid: pid,
                name: app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? "\(pid)",
                bundlePath: app.bundleURL?.path, isRegular: app.activationPolicy == .regular)
        }
        cache = identities
        return identities
    }
}

/// Icons for the rows on screen, each looked up once: an app's own icon for an app and a helper app's icon for a helper.
/// Anything without an icon of its own gets the popovers' placeholder, a grey tile with a gear: a plain program, which
/// the system would show as a black program icon, and a bundle that names no icon, which it would show as a blank one.
final class ProcessIcons {
    private static let size = NSSize(width: 16, height: 16)
    /// A process that is not an app is asked again only after this long, in case it was an app still starting.
    private static let retryAfter: TimeInterval = 5

    private var byBundle: [String: NSImage] = [:]
    private var byPID: [Int32: NSImage] = [:]
    /// When each process last turned out not to be an app with an icon. Most lines are plain processes, and asking the
    /// system about each of them on every update took a third of the time of refilling the table.
    private var notApps: [Int32: TimeInterval] = [:]
    /// The icon for each executable's path, as working out its bundle takes splitting the path.
    private var byPath: [String: NSImage] = [:]
    private var bundleHasIcon: [String: Bool] = [:]

    func icon(for usage: ProcessUsage, isApp: Bool) -> NSImage {
        if isApp {
            if let known = byPID[usage.pid] { return known }
            let now = ProcessInfo.processInfo.systemUptime
            if notApps[usage.pid].map({ now - $0 >= Self.retryAfter }) ?? true {
                if let app = NSRunningApplication(processIdentifier: usage.pid), let url = app.bundleURL,
                    url.pathExtension == "app", hasOwnIcon(url.path), let icon = app.icon
                {
                    let image = sized(icon)
                    byPID[usage.pid] = image
                    notApps[usage.pid] = nil
                    return image
                }
                notApps[usage.pid] = now
            }
        }
        guard let path = usage.path else { return ProcessPlaceholderIcon.image }
        if let known = byPath[path] { return known }
        let image = bundleIcon(of: path)
        if byPath.count >= 4096 { byPath.removeAll(keepingCapacity: true) }
        byPath[path] = image
        return image
    }

    private func bundleIcon(of path: String) -> NSImage {
        guard let bundle = ProcessGrouping.innermostBundle(of: path), hasOwnIcon(bundle) else {
            return ProcessPlaceholderIcon.image
        }
        if let known = byBundle[bundle] { return known }
        let image = sized(NSWorkspace.shared.icon(forFile: bundle))
        byBundle[bundle] = image
        return image
    }

    /// Whether the bundle names an icon in its Info.plist, read once for each bundle.
    private func hasOwnIcon(_ bundlePath: String) -> Bool {
        if let known = bundleHasIcon[bundlePath] { return known }
        let info = Bundle(path: bundlePath)?.infoDictionary ?? [:]
        let has = ["CFBundleIconFile", "CFBundleIconName", "CFBundleIcons"].contains { info[$0] != nil }
        bundleHasIcon[bundlePath] = has
        return has
    }

    /// Icons of apps that quit are not worth keeping.
    func forget(except pids: Set<Int32>) {
        byPID = byPID.filter { pids.contains($0.key) }
        notApps = notApps.filter { pids.contains($0.key) }
    }

    private func sized(_ image: NSImage) -> NSImage {
        // A copy, as the system hands out shared images whose size others may rely on.
        guard let copy = image.copy() as? NSImage else { return image }
        copy.size = Self.size
        return copy
    }
}
