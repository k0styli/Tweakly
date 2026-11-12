import FinderSync
import Foundation
import os

/// The Finder Sync extension inside the app, as System Settings sees it.
///
/// While it is enabled, Finder keeps its process running whether or not the tweak is on, so the tweak's switch turns it
/// on and off with `pluginkit`, the system's own tool for the same setting as Login Items & Extensions. That needs no
/// prompt, which is kinder than sending people to System Settings. Finder
/// starts the extension as soon as it is enabled, and ends it some seconds after it is not.
nonisolated enum FinderExtension {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "finder-menu")
    private static let pluginkit = URL(filePath: "/usr/bin/pluginkit")

    static var bundleID: String {
        (Bundle.main.bundleIdentifier ?? "me.tweakly.Tweakly") + ".FinderMenu"
    }

    /// Asks the system, which takes a moment, so not on every redraw.
    static var isEnabled: Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    /// The same as the switch in System Settings. Calls back on the main actor with whether `pluginkit` took it.
    static func setEnabled(_ isOn: Bool, then done: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        let process = Process()
        process.executableURL = pluginkit
        process.arguments = ["-e", isOn ? "use" : "ignore", "-i", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            let succeeded = process.terminationStatus == 0
            if !succeeded {
                log.error("pluginkit could not turn the extension \(isOn ? "on" : "off", privacy: .public)")
            }
            if let done {
                DispatchQueue.main.async { MainActor.assumeIsolated { done(succeeded) } }
            }
        }
        do {
            try process.run()
        } catch {
            log.error("pluginkit did not start: \(error.localizedDescription, privacy: .public)")
            if let done {
                DispatchQueue.main.async { MainActor.assumeIsolated { done(false) } }
            }
        }
    }
}
