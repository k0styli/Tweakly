import Darwin
import FinderMenuCore
import Foundation
import Security
import Synchronization
import os

/// The agent's end of the channel from the Finder extension: a Mach port registered under the service name while the
/// tweak is on.
///
/// An XPC listener needs a launchd job to own its name, which would mean a background item of its own, so the port is
/// registered directly, as `CFMessagePort` does. Unlike `CFMessagePort` this asks the kernel for each sender's audit
/// token and serves only code that satisfies the embedded extension's own designated requirement: the same certificate
/// and identifier, or for an ad-hoc build the same code hash. Messages come in on a queue of their own, so Finder gets
/// its answer even while the main thread is busy.
///
/// `@unchecked Sendable`: the port and the source never change after `init`, the requirement is immutable, the last
/// accepted token is touched only on `queue`, and the items are behind a mutex.
nonisolated final class FinderMenuServer: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// `bootstrap_register` is deprecated and could go one day; the tweak then turns off and says why.
        case noRegistration
        case port(kern_return_t)
        /// Another process holds the name, usually an agent on its way out. Worth trying again shortly.
        case nameTaken
    }

    private typealias Register = @convention(c) (mach_port_t, UnsafePointer<CChar>, mach_port_t) -> kern_return_t

    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "finder-menu")
    private static let headerSize = MemoryLayout<mach_msg_header_t>.size
    private static let trailerSize = MemoryLayout<mach_msg_audit_trailer_t>.size
    private static let bufferSize = headerSize + FinderMenuWire.maximumBody + trailerSize + 64
    /// `MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT)`, macros
    /// Swift does not import.
    private static let auditTrailer = Int32(bitPattern: UInt32(MACH_RCV_TRAILER_AUDIT) << 24)
    /// launchd's answer for a name in use.
    private static let bootstrapNotPrivileged: kern_return_t = 1100

    private let queue = DispatchQueue(label: "me.tweakly.Tweakly.finder-menu", qos: .userInitiated)
    private let port: mach_port_t
    private let source: DispatchSourceMachReceive
    private let requirement: SecRequirement
    private let items = Mutex(FinderMenuItems())
    private let buffer: UnsafeMutableRawPointer
    private var acceptedToken: Data?

    /// - Parameter handle: gets every request but `.items`, on the server's queue.
    init(
        serviceName: String, requirement: SecRequirement,
        handle: @escaping @Sendable (FinderMenuRequest) -> Void
    ) throws(Failure) {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_register") else {
            throw .noRegistration
        }
        let register = unsafeBitCast(symbol, to: Register.self)
        var port = mach_port_t(MACH_PORT_NULL)
        var result = mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
        guard result == KERN_SUCCESS else { throw .port(result) }
        result = mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
        guard result == KERN_SUCCESS else {
            mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
            throw .port(result)
        }
        var bootstrap = mach_port_t(MACH_PORT_NULL)
        result = task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap)
        if result == KERN_SUCCESS {
            result = register(bootstrap, serviceName, port)
            mach_port_deallocate(mach_task_self_, bootstrap)
        }
        // launchd keeps a send right of its own, and drops the name when the receive right goes.
        mach_port_deallocate(mach_task_self_, port)
        guard result == KERN_SUCCESS else {
            mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
            throw result == Self.bootstrapNotPrivileged ? .nameTaken : .port(result)
        }

        self.port = port
        self.requirement = requirement
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        source = DispatchSource.makeMachReceiveSource(port: port, queue: queue)
        let buffer = buffer
        source.setEventHandler { [weak self] in self?.receive(handle: handle) }
        source.setCancelHandler {
            mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
            buffer.deallocate()
        }
        source.activate()
    }

    /// What the next menu shows.
    func setItems(_ newItems: FinderMenuItems) {
        items.withLock { $0 = newItems }
    }

    /// Takes the name away at once: the extension's next lookup fails and its menu is empty.
    func stop() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }

    private func receive(handle: @Sendable (FinderMenuRequest) -> Void) {
        let header = buffer.assumingMemoryBound(to: mach_msg_header_t.self)
        let result = mach_msg(
            header, MACH_RCV_MSG | MACH_RCV_TIMEOUT | Self.auditTrailer, 0,
            mach_msg_size_t(Self.bufferSize), port, 0, mach_port_t(MACH_PORT_NULL))
        // Too large for any request: the kernel has already thrown it away.
        guard result == KERN_SUCCESS else { return }
        let size = Int(header.pointee.msgh_size)
        // Rights or memory attached to a message are released by destroying it, which also answers a waiting sender.
        guard header.pointee.msgh_bits & UInt32(MACH_MSGH_BITS_COMPLEX) == 0, size >= Self.headerSize,
            size <= Self.headerSize + FinderMenuWire.maximumBody, isFromExtension(trailerAt: (size + 3) & ~3)
        else {
            mach_msg_destroy(header)
            return
        }
        let body = UnsafeRawBufferPointer(start: buffer + Self.headerSize, count: size - Self.headerSize)
        guard let request = FinderMenuWire.decode(id: header.pointee.msgh_id, body: body) else {
            Self.log.error("Refused a request that did not decode")
            mach_msg_destroy(header)
            return
        }
        // Every request is answered, with what the menu shows. The sender waits for it, so it is still there to be
        // checked, and knows the work was taken on.
        reply(to: header, with: FinderMenuWire.encode(items.withLock { $0 }))
        if request != .items { handle(request) }
    }

    private func isFromExtension(trailerAt offset: Int) -> Bool {
        var token = (buffer + offset).assumingMemoryBound(to: mach_msg_audit_trailer_t.self).pointee.msgh_audit
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        // The token names one run of one process, so the extension is checked once and not on every menu.
        if data == acceptedToken { return true }
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code)
                == errSecSuccess,
            let code, SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        else {
            // The pid is the token's sixth word, as `audit_token_to_pid` in libbsm reads it.
            Self.log.error("Refused a message from \(token.val.5, privacy: .public): not our extension")
            return false
        }
        acceptedToken = data
        return true
    }

    private func reply(to request: UnsafeMutablePointer<mach_msg_header_t>, with payload: [UInt8]) {
        let replyPort = request.pointee.msgh_remote_port
        guard replyPort != MACH_PORT_NULL else { return }
        let size = (Self.headerSize + payload.count + 3) & ~3
        withUnsafeTemporaryAllocation(byteCount: size, alignment: 8) { message in
            message.initializeMemory(as: UInt8.self, repeating: 0)
            guard let base = message.baseAddress else { return }
            UnsafeMutableRawBufferPointer(rebasing: message[Self.headerSize...]).copyBytes(from: payload)
            let header = base.assumingMemoryBound(to: mach_msg_header_t.self)
            header.pointee.msgh_bits = UInt32(MACH_MSG_TYPE_MOVE_SEND_ONCE)
            header.pointee.msgh_size = mach_msg_size_t(size)
            header.pointee.msgh_remote_port = replyPort
            header.pointee.msgh_id = request.pointee.msgh_id
            // A sender that gave up has left a dead name, which this cannot wait on.
            let result = mach_msg(
                header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, mach_msg_size_t(size), 0, mach_port_t(MACH_PORT_NULL), 0,
                mach_port_t(MACH_PORT_NULL))
            if result != KERN_SUCCESS {
                Self.log.notice("The extension did not wait for its answer: \(result, privacy: .public)")
                // A failed send leaves the right with us.
                mach_port_deallocate(mach_task_self_, replyPort)
            }
        }
    }
}
