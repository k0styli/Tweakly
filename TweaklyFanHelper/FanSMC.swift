import Foundation
import IOKit
import os

/// PRIVATE INTERFACE. Writes to the fans through the SMC, which takes root. The selector, the command numbers and the
/// 80-byte structure are undocumented, as in the app's `SMCClient`, which only reads. Any failure is reported, and the
/// caller gives the fans back.
///
/// Checked on macOS 26.6.2 on an M1 Pro.
final class FanSMC {
    private static let structureSize = 80
    private static let selector: UInt32 = 2

    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let index = 44
        static let bytes = 48
    }

    private enum Command: UInt8 {
        case read = 5
        case write = 6
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func readByte(_ key: UInt32) -> UInt8? {
        perform(.read, key: key, size: 1)?[Offset.bytes]
    }

    func readFloat(_ key: UInt32) -> Float? {
        perform(.read, key: key, size: 4)?.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: Offset.bytes, as: Float.self)
        }
    }

    func exists(_ key: UInt32) -> Bool {
        perform(.keyInfo, key: key) != nil
    }

    func write(_ key: UInt32, byte: UInt8) -> Bool {
        perform(.write, key: key, size: 1, type: Self.code("ui8 ")) { $0[Offset.bytes] = byte } != nil
    }

    func write(_ key: UInt32, float: Float) -> Bool {
        perform(.write, key: key, size: 4, type: Self.code("flt ")) { bytes in
            withUnsafeBytes(of: float) { source in
                for (index, byte) in source.enumerated() { bytes[Offset.bytes + index] = byte }
            }
        } != nil
    }

    /// The keys of sensors worth watching for an emergency: the processor's and the graphics'.
    func temperatureKeys() -> [UInt32] {
        guard let data = perform(.read, key: Self.code("#KEY"), size: 4) else { return [] }
        let count = data[Offset.bytes..<(Offset.bytes + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let floatType = Self.code("flt ")
        var keys: [UInt32] = []
        for index in 0..<min(count, 20_000) {
            guard let found = perform(.keyAtIndex, index: UInt32(index)) else { continue }
            let key = found.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: Offset.key, as: UInt32.self) }
            let prefix = key >> 16
            guard prefix == Self.code("Tp") || prefix == Self.code("Te") || prefix == Self.code("Tg"),
                let info = perform(.keyInfo, key: key),
                info.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: Offset.dataType, as: UInt32.self) })
                    == floatType
            else { continue }
            keys.append(key)
        }
        return keys
    }

    private func perform(
        _ command: Command, key: UInt32 = 0, size: UInt32 = 0, type: UInt32 = 0, index: UInt32 = 0,
        fill: ((inout [UInt8]) -> Void)? = nil
    ) -> [UInt8]? {
        var input = [UInt8](repeating: 0, count: Self.structureSize)
        input.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: key, toByteOffset: Offset.key, as: UInt32.self)
            raw.storeBytes(of: size, toByteOffset: Offset.dataSize, as: UInt32.self)
            raw.storeBytes(of: type, toByteOffset: Offset.dataType, as: UInt32.self)
            raw.storeBytes(of: command.rawValue, toByteOffset: Offset.command, as: UInt8.self)
            raw.storeBytes(of: index, toByteOffset: Offset.index, as: UInt32.self)
        }
        fill?(&input)
        var output = [UInt8](repeating: 0, count: Self.structureSize)
        var outputSize = Self.structureSize
        let result = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                IOConnectCallStructMethod(
                    connection, Self.selector, inBytes.baseAddress, Self.structureSize, outBytes.baseAddress,
                    &outputSize)
            }
        }
        return result == KERN_SUCCESS && output[Offset.result] == 0 ? output : nil
    }
}
