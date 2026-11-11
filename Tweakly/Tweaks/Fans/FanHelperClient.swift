import FanControlCore
import Foundation

/// The app's side of the root helper. launchd starts the helper when this connects, and it leaves again when idle.
final class FanHelperClient {
    private static var label: String { FanHelper.label(forApp: Bundle.main.bundleIdentifier ?? "") }

    private var connection: NSXPCConnection?

    /// Whether the helper was installed for this copy of the app. Its launchd file is readable by anyone.
    static var isInstalled: Bool {
        #if TWEAKLY_AUTOMATION
            // To look at the page as it is with a helper, on a Mac with no fans to install one for.
            if UserDefaults.standard.bool(forKey: "fanHelperAssumed") { return true }
        #endif
        return FileManager.default.fileExists(
            atPath: FanHelper.launchdPlist(forApp: Bundle.main.bundleIdentifier ?? ""))
    }

    isolated deinit {
        connection?.invalidate()
    }

    /// `done` runs on the main thread with an error, or nil.
    func setFans(
        _ targets: [Double], lease: Double, emergency: Double, done: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let proxy = proxy { error in
            Task { @MainActor in done(error) }
        }
        proxy?.setFans(targets.map(NSNumber.init(value:)), lease: lease, emergency: emergency) { error in
            Task { @MainActor in done(error) }
        }
    }

    func returnToSystem() {
        proxy { _ in }?.returnToSystem {}
    }

    /// `done` runs on the main thread with the helper's version, or nil if it cannot be reached.
    func version(done: @escaping @MainActor @Sendable (Int?) -> Void) {
        let proxy = proxy { _ in
            Task { @MainActor in done(nil) }
        }
        proxy?.version { version in
            Task { @MainActor in done(version) }
        }
    }

    /// Letting go is what tells the helper the app no longer needs it, if the fans are still held.
    func close() {
        connection?.invalidate()
        connection = nil
    }

    private func proxy(onError: @escaping @Sendable (String) -> Void) -> FanHelperProtocol? {
        let connection = self.connection ?? makeConnection()
        self.connection = connection
        // Marked as sendable because these run on XPC's own queue, where anything tied to the main thread would stop the app.
        return connection.remoteObjectProxyWithErrorHandler { @Sendable error in
            onError(error.localizedDescription)
        } as? FanHelperProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: Self.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        // Only this connection: a late word from one already replaced must not drop the newer one, whose release would
        // give the fans back.
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                if let current = self?.connection, ObjectIdentifier(current) == id { self?.connection = nil }
            }
        }
        connection.resume()
        return connection
    }
}
