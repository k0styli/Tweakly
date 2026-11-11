import Foundation
import IOKit
import IOKit.storage

/// Reads the built-in drive's own health log. The interface is declared in IOKit's public
/// `NVMeSMARTLibExternal.h`, which Swift cannot import, so its layout is written out here. It needs no
/// privileges and takes under a millisecond. Checked on macOS 27.2 on an M2. Anything unexpected, including
/// a newer version of the interface whose layout may differ, means no reading, not a wrong one.
enum DriveHealthReader {
    private static let deviceClass = "IOEmbeddedNVMeBlockDevice"
    private static let supportedVersion: UInt16 = 1
    private static let logSize = 512
    /// IUnknown's four pointers, then the 16-bit version.
    private static let versionOffset = 32
    /// Past the version and revision, padded to eight bytes.
    private static let readFunctionOffset = 40
    /// The standard counts data in units of a thousand 512-byte blocks.
    private static let bytesPerDataUnit: UInt64 = 512_000
    private static let absoluteZero = 273.15

    private typealias ReadFunction = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> IOReturn

    static func read() -> DriveHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(deviceClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let log = readLog(from: service) else { return nil }
        var health = health(fromLog: log)
        let value = IORegistryEntryCreateCFProperty(
            service, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)
        let characteristics = value?.takeRetainedValue() as? [String: Any]
        health?.model = (characteristics?["Product Name"] as? String)?.trimmingCharacters(in: .whitespaces)
        return health
    }

    /// Interprets the log, whose fields the NVMe standard fixes.
    static func health(fromLog log: [UInt8]) -> DriveHealth? {
        guard log.count >= logSize else { return nil }
        func counter(at offset: Int) -> UInt64 {
            // The fields hold 128 bits, of which the top half stays zero for anything a drive will ever reach.
            log[offset..<(offset + 8)].reversed().reduce(0) { ($0 << 8) | UInt64($1) }
        }
        let kelvin = Int(log[1]) | Int(log[2]) << 8
        return DriveHealth(
            model: nil,
            temperature: kelvin > 0 ? Double(kelvin) - absoluteZero : nil,
            wear: Double(log[5]) / 100,
            bytesRead: counter(at: 32).multipliedReportingOverflow(by: bytesPerDataUnit).partialValue,
            bytesWritten: counter(at: 48).multipliedReportingOverflow(by: bytesPerDataUnit).partialValue,
            hasWarning: log[0] != 0
        )
    }

    private static func readLog(from service: io_service_t) -> [UInt8]? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard
            IOCreatePlugInInterfaceForService(service, userClientType, plugInInterface, &plugin, &score)
                == KERN_SUCCESS, let plugin, let table = plugin.pointee
        else { return nil }
        defer { IODestroyPlugInInterface(plugin) }

        var interface: LPVOID?
        guard table.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterface), &interface) == 0,
            let interface
        else { return nil }
        let functions = interface.assumingMemoryBound(to: UnsafeRawPointer.self).pointee
        defer {
            // Pairs with the reference that the query above took on the interface.
            let release = unsafeBitCast(
                functions.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.stride * 3, as: UnsafeRawPointer.self),
                to: (@convention(c) (UnsafeMutableRawPointer) -> UInt32).self
            )
            _ = release(interface)
        }
        guard functions.load(fromByteOffset: versionOffset, as: UInt16.self) == supportedVersion else { return nil }
        let readFunction = unsafeBitCast(
            functions.load(fromByteOffset: readFunctionOffset, as: UnsafeRawPointer.self), to: ReadFunction.self)

        var log = [UInt8](repeating: 0, count: logSize)
        let result = log.withUnsafeMutableBytes { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnNoMemory }
            return readFunction(interface, base)
        }
        return result == kIOReturnSuccess ? log : nil
    }

    // From `NVMeSMARTLibExternal.h` and `IOCFPlugIn.h`, whose macros Swift cannot import.
    private static var userClientType: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
    }

    private static var smartInterface: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
    }

    private static var plugInInterface: CFUUID {
        CFUUIDGetConstantUUIDWithBytes(
            nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    }
}
