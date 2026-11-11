import Foundation
import Synchronization

/// Finds the address the internet sees, which only something outside can say. It asks Cloudflare's trace
/// page, which also gives the country and needs no account. A request goes out only while details are on
/// screen, and no more often than `refreshInterval` unless the local address changes.
final class PublicAddressReader {
    private struct State {
        var address: PublicAddress?
        var lastAttempt: TimeInterval?
        var lastLocalAddress: String?
        var isRunning = false
        /// The network changed while a request was out, so its answer describes the old one.
        var answerIsStale = false
    }

    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private static let refreshInterval: TimeInterval = 120
    private static let timeout: TimeInterval = 5
    private static let url = URL(string: "https://1.1.1.1/cdn-cgi/trace")

    private let shared = Shared()

    /// The latest answer, asking for a new one in the background when it is due.
    func current(localAddress: String?) -> PublicAddress? {
        let now = uptimeSeconds()
        let (address, isDue) = shared.state.withLock { state in
            let moved = state.lastLocalAddress != localAddress
            if moved {
                state.address = nil
                state.answerIsStale = state.isRunning
            }
            state.lastLocalAddress = localAddress
            let isStale = state.lastAttempt.map { now - $0 >= Self.refreshInterval } ?? true
            let isDue = !state.isRunning && (moved || isStale || state.lastAttempt == nil)
            if isDue {
                state.isRunning = true
                state.lastAttempt = now
            }
            return (state.address, isDue)
        }
        if isDue { Self.fetch(shared) }
        return address
    }

    private static func fetch(_ shared: Shared) {
        guard let url else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: url) { data, _, _ in
            let address = data.flatMap { parse(String(decoding: $0, as: UTF8.self)) }
            shared.state.withLock { state in
                state.isRunning = false
                if state.answerIsStale {
                    state.answerIsStale = false
                    state.lastAttempt = nil
                } else {
                    state.address = address
                }
            }
        }
        task.resume()
        session.finishTasksAndInvalidate()
    }

    /// Reads `key=value` lines, of which only the address is required.
    static func parse(_ text: String) -> PublicAddress? {
        var values: [Substring: Substring] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        guard let address = values["ip"], !address.isEmpty else { return nil }
        // `T1` means Tor and `XX` means unknown, and neither has a flag.
        let country = values["loc"].flatMap { code in
            code.count == 2 && code != "XX" && code.allSatisfy { $0.isASCII && $0.isLetter } ? String(code) : nil
        }
        return PublicAddress(address: String(address), countryCode: country)
    }
}
