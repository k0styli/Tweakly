import Foundation

/// What the root helper offers the app, and all it offers: nothing here can name an SMC key or run anything. It sets the
/// fans, and for the task manager it reads the figures of processes the app cannot read itself and ends one process at a
/// time.
@objc public protocol FanHelperProtocol {
    /// So that the app can tell it has to install a newer one.
    func version(reply: @escaping @Sendable (Int) -> Void)

    /// Sets each fan: an rpm, or a negative number for the system. The helper keeps every rpm within the fan's limits. It
    /// gives the fans back by itself when `lease` seconds pass with no new call, when the connection goes, or at
    /// `emergency` degrees. The reply holds an error, or nil.
    func setFans(_ targets: [NSNumber], lease: Double, emergency: Double, reply: @escaping @Sendable (String?) -> Void)

    /// Gives every fan back to the system, the way it was found.
    func returnToSystem(reply: @escaping @Sendable () -> Void)

    /// The figures of the processes named, which other users' processes give only to root. Each process answers
    /// `ProcessFigures.count` numbers in a row, in the order of `ProcessFigures.Field`. One that is gone is left out.
    /// Reading changes nothing.
    func processFigures(_ pids: [NSNumber], reply: @escaping @Sendable ([NSNumber]) -> Void)

    /// Ends the one process named: `SIGTERM`, or `SIGKILL` with `force`. `start` is when the app saw it start, in mach
    /// time, so a later process that was given the same number is left alone; zero skips that check. The helper refuses
    /// the kernel, launchd and itself. The app asks only after a person confirmed it in a dialog that names the process.
    /// The reply holds an error, or nil.
    func endProcess(_ pid: Int32, start: UInt64, force: Bool, reply: @escaping @Sendable (String?) -> Void)
}

/// How the helper lays out the figures of one process.
public enum ProcessFigures {
    public enum Field: Int, CaseIterable {
        case pid, start, cpuTime, memory, diskRead, diskWritten, threads
    }

    public static let count = Field.allCases.count
    /// More than a Mac runs, so that a request cannot keep the helper busy for long.
    public static let mostPerRequest = 8192
}

public enum FanHelper {
    /// Raised when the helper's behaviour changes, which asks the owner of the Mac to install it again.
    /// 2 added reading and ending processes for the task manager. 3 trusts the team of a Developer ID signature rather
    /// than one certificate.
    public static let currentVersion = 3
    /// One label for each copy of the app, so that a test copy never reaches the helper of the real one.
    public static func label(forApp bundleID: String) -> String { bundleID + ".fanhelper" }
    /// Where launchd finds it, readable by anyone, which is how the app tells it is installed.
    public static func launchdPlist(forApp bundleID: String) -> String {
        "/Library/LaunchDaemons/\(label(forApp: bundleID)).plist"
    }
    public static let clientArgument = "--client"
}
