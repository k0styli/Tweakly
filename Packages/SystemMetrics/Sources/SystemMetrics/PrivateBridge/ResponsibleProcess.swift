import Darwin

/// PRIVATE INTERFACE. Which app macOS holds responsible for a process, the way it decides whose permission a helper uses.
/// The task manager puts a service launchd started for an app, such as Safari's web content or a widget's view service,
/// into that app's row with it. Checked on macOS 27.2 on an M2: it answers for the user's own processes, about 320 of 500,
/// and the rest are left to the parent and the bundle. Without the symbol, grouping goes by those alone.
public enum ResponsibleProcess {
    /// A function pointer looked up once and never changed, which is what makes sharing it safe.
    private struct Symbols: @unchecked Sendable {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        let lookup: Lookup?

        init() {
            let library = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_LAZY)
            lookup = PrivateSymbols.find("responsibility_get_pid_responsible_for_pid", in: library).map {
                unsafeBitCast($0, to: Lookup.self)
            }
        }
    }

    private static let symbols = Symbols()

    /// The responsible process, or nil when it is the process itself or cannot be told.
    public static func pid(responsibleFor pid: Int32) -> Int32? {
        guard let lookup = symbols.lookup else { return nil }
        let responsible = lookup(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }
}
