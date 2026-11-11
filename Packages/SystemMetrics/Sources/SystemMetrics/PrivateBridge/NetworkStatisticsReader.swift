import Darwin
import Foundation
import Synchronization

/// Bytes a second each process receives and sends, from whichever source works.
public protocol ProcessNetworkRates: AnyObject {
    /// The rates over the last interval. The call also starts the next interval where the source needs asking.
    func rates() -> [Int32: NetworkRateReader.Rates]
}

extension NetworkRateReader: ProcessNetworkRates {}

/// PRIVATE INTERFACE. The kernel's per-connection traffic counters, through the NetworkStatistics framework that `nettop`
/// itself uses. Checked on macOS 27.2 on an M2: it needs no entitlement and no root, and sees the connections of every
/// user's processes. Each call to `rates()` asks for fresh counters; the answers arrive on a queue of their own, and a
/// rate covers the time between two answers, about a second. A missing symbol makes `init` fail, and the task manager
/// falls back to `NetworkRateReader`, which is updated every 5 seconds.
public final class NetworkStatisticsReader: ProcessNetworkRates {
    /// Function pointers looked up once and never changed, which is what makes sharing them safe.
    private struct Symbols: @unchecked Sendable {
        typealias AddedBlock = @convention(block) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
        typealias DictionaryBlock = @convention(block) (CFDictionary?) -> Void
        typealias VoidBlock = @convention(block) () -> Void
        // The framework keeps every block it is given, so each must be marked as escaping, or Swift stops the app the
        // first time the framework calls one later.
        typealias Create =
            @convention(c) (CFAllocator?, DispatchQueue, @escaping AddedBlock) -> UnsafeMutableRawPointer?
        typealias ManagerCall = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias SetDictionaryBlock = @convention(c) (UnsafeMutableRawPointer, @escaping DictionaryBlock) -> Void
        typealias SetVoidBlock = @convention(c) (UnsafeMutableRawPointer, @escaping VoidBlock) -> Void
        typealias QueryAll = @convention(c) (UnsafeMutableRawPointer, VoidBlock?) -> Void
        typealias SourceCall = @convention(c) (UnsafeMutableRawPointer) -> Void

        let create: Create
        let addAllTCP: ManagerCall
        let addAllUDP: ManagerCall
        let destroy: ManagerCall
        let setDescription: SetDictionaryBlock
        let setCounts: SetDictionaryBlock
        let setRemoved: SetVoidBlock
        let queryAll: QueryAll
        let queryDescription: SourceCall
        let pidKey: CFString
        let receivedKey: CFString
        let sentKey: CFString

        init?() {
            let framework = dlopen(
                "/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY)
            func symbol<Function>(_ name: String, as type: Function.Type) -> Function? {
                PrivateSymbols.find(name, in: framework).map { unsafeBitCast($0, to: type) }
            }
            func key(_ name: String) -> CFString? {
                PrivateSymbols.find(name, in: framework)?.assumingMemoryBound(to: CFString.self).pointee
            }
            guard let create = symbol("NStatManagerCreate", as: Create.self),
                let addAllTCP = symbol("NStatManagerAddAllTCP", as: ManagerCall.self),
                let addAllUDP = symbol("NStatManagerAddAllUDP", as: ManagerCall.self),
                let destroy = symbol("NStatManagerDestroy", as: ManagerCall.self),
                let setDescription = symbol("NStatSourceSetDescriptionBlock", as: SetDictionaryBlock.self),
                let setCounts = symbol("NStatSourceSetCountsBlock", as: SetDictionaryBlock.self),
                let setRemoved = symbol("NStatSourceSetRemovedBlock", as: SetVoidBlock.self),
                let queryAll = symbol("NStatManagerQueryAllSources", as: QueryAll.self),
                let queryDescription = symbol("NStatSourceQueryDescription", as: SourceCall.self),
                let pidKey = key("kNStatSrcKeyPID"), let receivedKey = key("kNStatSrcKeyRxBytes"),
                let sentKey = key("kNStatSrcKeyTxBytes")
            else { return nil }
            (self.create, self.addAllTCP, self.addAllUDP, self.destroy) = (create, addAllTCP, addAllUDP, destroy)
            (self.setDescription, self.setCounts, self.setRemoved) = (setDescription, setCounts, setRemoved)
            (self.queryAll, self.queryDescription) = (queryAll, queryDescription)
            (self.pidKey, self.receivedKey, self.sentKey) = (pidKey, receivedKey, sentKey)
        }
    }

    private struct Connection {
        var pid: Int32?
        var received: UInt64?
        var sent: UInt64?
        /// Connections already open when watching began have counted bytes from before, which are not a rate.
        var countsFromStart: Bool
    }

    private struct State {
        var connections: [Int: Connection] = [:]
        /// Bytes since the last answer, by process.
        var pending: [Int32: (received: UInt64, sent: UInt64)] = [:]
        var lastAnswer: TimeInterval?
        var rates: [Int32: NetworkRateReader.Rates] = [:]
        var isAsking = false
        var hasAnswered = false
    }

    /// Reached from the framework's callbacks on `queue` and from `rates()`, so it is behind a lock.
    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    /// The framework's manager. `@unchecked Sendable`: after it is made, it is only ever used on `queue`, the queue it
    /// calls back on, so no two calls to it overlap.
    private struct Manager: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
    }

    private static let symbols = Symbols()

    private let symbols: Symbols
    private let queue = DispatchQueue(label: "me.tweakly.Tweakly.network-statistics", qos: .utility)
    private let shared = Shared()
    private let manager: Manager

    public init?() {
        guard let symbols = Self.symbols else { return nil }
        self.symbols = symbols
        let shared = shared
        let added: Symbols.AddedBlock = { source, _ in
            guard let source else { return }
            let id = Int(bitPattern: source)
            shared.state.withLock { state in
                state.connections[id] = Connection(countsFromStart: state.hasAnswered)
            }
            symbols.setDescription(source) { description in
                guard let pid = Self.number(symbols.pidKey, in: description) else { return }
                shared.state.withLock { $0.connections[id]?.pid = Int32(truncatingIfNeeded: pid) }
            }
            symbols.setCounts(source) { counts in
                Self.count(counts, of: id, symbols: symbols, shared: shared)
            }
            symbols.setRemoved(source) {
                shared.state.withLock { _ = $0.connections.removeValue(forKey: id) }
            }
            symbols.queryDescription(source)
        }
        guard let pointer = symbols.create(kCFAllocatorDefault, queue, added) else { return nil }
        let manager = Manager(pointer: pointer)
        self.manager = manager
        queue.async {
            symbols.addAllTCP(manager.pointer)
            symbols.addAllUDP(manager.pointer)
        }
    }

    deinit {
        let (destroy, manager) = (symbols.destroy, manager)
        // The callbacks run on this queue, so destroying it there means none is halfway through. Create hands over a
        // reference that Destroy does not give back: checked on macOS 27.2 with `leaks`, each manager stayed behind,
        // about 4.7 KB for every visit to the task manager, until it was also released here.
        queue.async {
            destroy(manager.pointer)
            Unmanaged<AnyObject>.fromOpaque(manager.pointer).release()
        }
    }

    public func rates() -> [Int32: NetworkRateReader.Rates] {
        let shouldAsk = shared.state.withLock { state -> Bool in
            guard !state.isAsking else { return false }
            state.isAsking = true
            return true
        }
        if shouldAsk {
            let (shared, manager, queryAll) = (shared, manager, symbols.queryAll)
            queue.async {
                queryAll(manager.pointer) { Self.answered(shared) }
            }
        }
        return shared.state.withLock { $0.rates }
    }

    private static func count(_ counts: CFDictionary?, of id: Int, symbols: Symbols, shared: Shared) {
        let received = number(symbols.receivedKey, in: counts)
        let sent = number(symbols.sentKey, in: counts)
        let pid = number(symbols.pidKey, in: counts).map { Int32(truncatingIfNeeded: $0) }
        shared.state.withLock { state in
            guard var connection = state.connections[id] else { return }
            if let pid { connection.pid = pid }
            let newReceived = received ?? connection.received ?? 0
            let newSent = sent ?? connection.sent ?? 0
            let baseline = (connection.received, connection.sent)
            connection.received = newReceived
            connection.sent = newSent
            state.connections[id] = connection
            guard let owner = connection.pid else { return }
            var delta: (UInt64, UInt64)
            switch baseline {
            case (let oldReceived?, let oldSent?):
                // A counter that went back belongs to something new, and counts as nothing this time.
                delta = (
                    newReceived >= oldReceived ? newReceived - oldReceived : 0,
                    newSent >= oldSent ? newSent - oldSent : 0
                )
            default:
                guard connection.countsFromStart else { return }
                delta = (newReceived, newSent)
            }
            let previous = state.pending[owner] ?? (0, 0)
            state.pending[owner] = (previous.received &+ delta.0, previous.sent &+ delta.1)
        }
    }

    private static func answered(_ shared: Shared) {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
        shared.state.withLock { state in
            defer {
                state.pending = [:]
                state.lastAnswer = now
                state.isAsking = false
                state.hasAnswered = true
            }
            guard let last = state.lastAnswer, now - last > minimumSampleInterval else { return }
            let elapsed = now - last
            state.rates = state.pending.mapValues {
                NetworkRateReader.Rates(receive: Double($0.received) / elapsed, send: Double($0.sent) / elapsed)
            }
        }
    }

    private static func number(_ key: CFString, in dictionary: CFDictionary?) -> UInt64? {
        guard let dictionary, let value = (dictionary as NSDictionary)[key] as? NSNumber else { return nil }
        return value.uint64Value
    }
}
