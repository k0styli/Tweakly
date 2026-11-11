import Darwin
import Foundation
import Synchronization

/// Measures the round trip to a public resolver once a second while details are on screen. It uses the
/// unprivileged ICMP socket, which needs no root and no permission for an address outside the local
/// network. Checked on macOS 27.2: within a millisecond of `ping`. The router is not measured, because
/// reaching the local network would make macOS ask for permission.
final class LatencyMonitor {
    private static let target = "1.1.1.1"
    private static let interval: TimeInterval = 1
    /// Longer than any answer worth waiting for, and short enough that a lost packet shows soon.
    private static let timeout: TimeInterval = 2
    private static let historyLength = NetworkLatency.capacity
    /// Enough answers for a steady figure that still follows a change within seconds.
    private static let averagedAnswers = 10

    private struct State {
        var history: [Double?] = []
        var pending: [UInt16: TimeInterval] = [:]
        // Any process's ping reaches this kind of socket too. A random start keeps it apart from one that
        // counts from zero, on top of the check of who the reply came from.
        var nextSequence = UInt16.random(in: .min ... .max)

        mutating func record(_ result: Double?) {
            history.append(result)
            if history.count > LatencyMonitor.historyLength { history.removeFirst() }
        }
    }

    private final class Shared: Sendable {
        let state = Mutex(State())
    }

    private let shared = Shared()
    private let timer: DispatchSourceTimer
    private let reader: DispatchSourceRead

    init?() {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard descriptor >= 0 else {
            metricsLog.notice("Could not open an ICMP socket: \(errno, privacy: .public)")
            return nil
        }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            close(descriptor)
            return nil
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        guard inet_pton(AF_INET, Self.target, &address.sin_addr) == 1 else {
            close(descriptor)
            return nil
        }

        let queue = DispatchQueue(label: "me.tweakly.Tweakly.latency", qos: .utility)
        let shared = shared
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let targetAddress = address.sin_addr.s_addr
        reader.setEventHandler { Self.receive(descriptor, from: targetAddress, shared: shared) }
        reader.setCancelHandler { close(descriptor) }
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(100))
        let target = address
        timer.setEventHandler { Self.send(descriptor, to: target, shared: shared) }
        reader.resume()
        timer.resume()
    }

    deinit {
        timer.cancel()
        reader.cancel()
    }

    func current() -> NetworkLatency {
        let history = shared.state.withLock { $0.history }
        return Self.statistics(from: history)
    }

    /// The average and jitter of the latest answers, and the share of all recent packets that were lost.
    static func statistics(from history: [Double?]) -> NetworkLatency {
        var latency = NetworkLatency(samples: history)
        guard !history.isEmpty else { return latency }
        latency.loss = Double(history.filter { $0 == nil }.count) / Double(history.count)
        let answers = history.compactMap { $0 }.suffix(averagedAnswers)
        guard !answers.isEmpty else { return latency }
        latency.average = answers.reduce(0, +) / Double(answers.count)
        if answers.count >= 2 {
            let steps = zip(answers, answers.dropFirst()).map { abs($1 - $0) }
            latency.jitter = steps.reduce(0, +) / Double(steps.count)
        }
        return latency
    }

    private static func send(_ descriptor: Int32, to address: sockaddr_in, shared: Shared) {
        let now = uptimeSeconds()
        let sequence = shared.state.withLock { state -> UInt16 in
            for (sequence, sent) in state.pending where now - sent >= timeout {
                state.pending[sequence] = nil
                state.record(nil)
            }
            let sequence = state.nextSequence
            state.nextSequence &+= 1
            state.pending[sequence] = now
            return sequence
        }
        let packet = echoRequest(sequence: sequence)
        var target = address
        // No route counts as a lost packet too, once its time is up.
        _ = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(descriptor, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private static func receive(_ descriptor: Int32, from target: in_addr_t, shared: Shared) {
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length)
                }
            }
            guard count > 0 else { return }
            guard source.sin_addr.s_addr == target, let sequence = sequence(ofReply: buffer[0..<count]) else {
                continue
            }
            let now = uptimeSeconds()
            shared.state.withLock { state in
                guard let sent = state.pending.removeValue(forKey: sequence) else { return }
                state.record((now - sent) * 1000)
            }
        }
    }

    static func echoRequest(sequence: UInt16) -> [UInt8] {
        // The kernel fills in its own identifier for this kind of socket.
        var packet: [UInt8] = [8, 0, 0, 0, 0, 0, UInt8(sequence >> 8), UInt8(sequence & 255)]
        packet += [UInt8](repeating: 0, count: 16)
        var sum: UInt32 = 0
        for index in stride(from: 0, to: packet.count, by: 2) {
            sum &+= UInt32(packet[index]) << 8 | UInt32(packet[index + 1])
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        let checksum = ~UInt16(sum)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 255)
        return packet
    }

    /// The sequence number of an echo reply. Replies arrive with their IP header in front.
    static func sequence(ofReply bytes: ArraySlice<UInt8>) -> UInt16? {
        let data = Array(bytes)
        guard let first = data.first else { return nil }
        let offset = first >> 4 == 4 ? Int(first & 0x0f) * 4 : 0
        guard data.count >= offset + 8, data[offset] == 0 else { return nil }
        return UInt16(data[offset + 6]) << 8 | UInt16(data[offset + 7])
    }
}
