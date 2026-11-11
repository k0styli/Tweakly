import Darwin
import Foundation

/// Looks up private symbols, and lets a test pretend one is missing: the environment variable
/// `TWEAKLY_HIDE_PRIVATE_SYMBOLS`, a comma-separated list of names, makes those lookups fail, which is how the fallback
/// of each private interface is checked. Only the person starting the process can set it, and it can only take features
/// away.
enum PrivateSymbols {
    private static let hidden: Set<String> = Set(
        (ProcessInfo.processInfo.environment["TWEAKLY_HIDE_PRIVATE_SYMBOLS"] ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })

    static func find(_ name: String, in handle: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        guard let handle, !hidden.contains(name) else { return nil }
        return dlsym(handle, name)
    }
}
