import Darwin
import FinderMenuCore
import Foundation
import os

/// The extension's end of the channel to the agent: one Mach message there, and one back.
///
/// The agent cannot vend an XPC service without a launchd job, so it registers a plain Mach port while the tweak is on
/// and checks each sender's signature by the audit token the kernel attaches. The sandbox lets this extension look up
/// that one name and no other (`temporary-exception.mach-lookup.global-name`).
enum AgentChannel {
    /// The agent answers from a queue of its own, so this only runs out when it is gone or stopped.
    private static let timeout: mach_msg_timeout_t = 250
    private static let headerSize = MemoryLayout<mach_msg_header_t>.size
    private static let log = Logger(subsystem: "me.tweakly.Tweakly.findermenu", category: "channel")

    private typealias LookUp =
        @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>)
        -> kern_return_t

    /// Public in `servers/bootstrap.h` but not imported into Swift, so resolved here. If it ever goes, the menu is
    /// simply empty.
    private static let lookUp: LookUp? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_look_up")
        .map { unsafeBitCast($0, to: LookUp.self) }

    private static let serviceName: String? = Bundle.main.bundleIdentifier
        .flatMap(FinderMenuWire.appBundleID(forExtension:))
        .map(FinderMenuWire.serviceName(forApp:))

    /// What to show. Nothing when the agent is not running or the tweak is off.
    static func items() -> FinderMenuItems {
        guard let reply = exchange(.items) else { return [] }
        return FinderMenuWire.decodeItems(reply) ?? []
    }

    /// Hands a request to the agent, which does the work and says itself if something went wrong. The agent answers
    /// once it has checked who is asking, which it can do only while this process is there to wait.
    static func send(_ request: FinderMenuRequest) {
        if exchange(request) == nil {
            log.error("The agent did not take the request")
        }
    }

    private static func exchange(_ request: FinderMenuRequest) -> [UInt8]? {
        guard let server = lookUpServer() else { return nil }
        defer { mach_port_deallocate(mach_task_self_, server) }
        let (id, body) = FinderMenuWire.encode(request)
        let sendSize = headerSize + body.count
        // The reply is four bytes, and the default trailer is eight.
        let bufferSize = max(sendSize, headerSize + 64)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: bufferSize)
        UnsafeMutableRawBufferPointer(start: buffer + headerSize, count: body.count).copyBytes(from: body)

        var replyPort = mach_port_t(MACH_PORT_NULL)
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &replyPort) == KERN_SUCCESS else {
            return nil
        }
        defer { mach_port_mod_refs(mach_task_self_, replyPort, MACH_PORT_RIGHT_RECEIVE, -1) }

        let header = buffer.assumingMemoryBound(to: mach_msg_header_t.self)
        header.pointee.msgh_bits = UInt32(MACH_MSG_TYPE_COPY_SEND) | UInt32(MACH_MSG_TYPE_MAKE_SEND_ONCE) << 8
        header.pointee.msgh_size = mach_msg_size_t(sendSize)
        header.pointee.msgh_remote_port = server
        header.pointee.msgh_local_port = replyPort
        header.pointee.msgh_id = id

        let result = mach_msg(
            header, MACH_SEND_MSG | MACH_SEND_TIMEOUT | MACH_RCV_MSG | MACH_RCV_TIMEOUT, mach_msg_size_t(sendSize),
            mach_msg_size_t(bufferSize), replyPort, timeout, mach_port_t(MACH_PORT_NULL))
        guard result == KERN_SUCCESS else {
            // A send that timed out, the agent's queue being full, comes back with its rights, one more on the agent's
            // port and the reply's, which would otherwise stay with this process for good.
            if result == MACH_SEND_TIMED_OUT { mach_msg_destroy(header) }
            log.notice("No answer from the agent: \(result, privacy: .public)")
            return nil
        }
        // A refusal arrives as the system's notice that the reply right was destroyed, with an ID of its own.
        let size = Int(header.pointee.msgh_size)
        guard size >= headerSize, size <= bufferSize, header.pointee.msgh_id == id else { return nil }
        return Array(UnsafeRawBufferPointer(start: buffer + headerSize, count: size - headerSize))
    }

    private static func lookUpServer() -> mach_port_t? {
        guard let lookUp, let serviceName else { return nil }
        var bootstrap = mach_port_t(MACH_PORT_NULL)
        guard task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap) == KERN_SUCCESS else {
            return nil
        }
        defer { mach_port_deallocate(mach_task_self_, bootstrap) }
        var server = mach_port_t(MACH_PORT_NULL)
        // Fails at once while the agent is not running or the tweak is off, which is the usual way to say no menu.
        guard lookUp(bootstrap, serviceName, &server) == KERN_SUCCESS else { return nil }
        return server
    }
}
