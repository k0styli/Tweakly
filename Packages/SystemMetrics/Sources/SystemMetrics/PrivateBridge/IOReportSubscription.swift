import Foundation
import IOKit

private typealias CopyChannels =
    @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
private typealias CreateSubscription =
    @convention(c) (
        UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64,
        CFTypeRef?
    ) -> Unmanaged<AnyObject>?
private typealias CreateSamples =
    @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias ChannelText = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias StateCount = @convention(c) (CFDictionary) -> Int32
private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64
private typealias SimpleValue = @convention(c) (CFDictionary, UnsafeMutablePointer<Int32>?) -> Int64

/// PRIVATE INTERFACE. A subscription to `libIOReport` channels, which say what the chip's blocks have
/// been doing. No public API reports any of this.
///
/// Symbols are resolved at runtime, so a macOS that drops them only costs the values read here. Checked
/// on macOS 27.2 on an M2. Channels stay Core Foundation objects throughout, because IOReport rejects a
/// dictionary bridged through Swift.
final class IOReportSubscription {
    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let channelName: ChannelText
    private let unitLabel: ChannelText
    private let stateCount: StateCount
    private let stateName: StateName
    private let stateResidency: StateResidency
    private let simpleValue: SimpleValue
    private let subscription: AnyObject
    private let channels: CFMutableDictionary
    private var previous: CFDictionary?

    init?(group: String, subgroup: String?) {
        // A system library that lives in the shared cache, so it is deliberately never closed.
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            PrivateSymbols.find(name, in: library).map { unsafeBitCast($0, to: type) }
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", as: CopyChannels.self),
            let subscribe = symbol("IOReportCreateSubscription", as: CreateSubscription.self),
            let createSamples = symbol("IOReportCreateSamples", as: CreateSamples.self),
            let createDelta = symbol("IOReportCreateSamplesDelta", as: CreateDelta.self),
            let channelName = symbol("IOReportChannelGetChannelName", as: ChannelText.self),
            let unitLabel = symbol("IOReportChannelGetUnitLabel", as: ChannelText.self),
            let stateCount = symbol("IOReportStateGetCount", as: StateCount.self),
            let stateName = symbol("IOReportStateGetNameForIndex", as: StateName.self),
            let stateResidency = symbol("IOReportStateGetResidency", as: StateResidency.self),
            let simpleValue = symbol("IOReportSimpleGetIntegerValue", as: SimpleValue.self),
            let channels = copyChannels(group as CFString, subgroup.map { $0 as CFString }, 0, 0, 0)?
                .takeRetainedValue()
        else {
            metricsLog.notice("IOReport has no channels for \(group, privacy: .public)")
            return nil
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, channels, &subscribed, 0, nil)?.takeRetainedValue(),
            let subscribedChannels = subscribed?.takeRetainedValue()
        else {
            metricsLog.notice("IOReport refused a subscription to \(group, privacy: .public)")
            return nil
        }

        self.createSamples = createSamples
        self.createDelta = createDelta
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        self.simpleValue = simpleValue
        self.subscription = subscription
        self.channels = subscribedChannels
    }

    /// Each channel's change since the previous call. The first call only takes the baseline, so returns nil.
    func changes() -> [CFDictionary]? {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        defer { previous = current }
        guard let previous, let delta = createDelta(previous, current, nil)?.takeRetainedValue() else { return nil }
        let key = "IOReportChannels" as CFString
        guard let rawItems = CFDictionaryGetValue(delta, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        // The library's data is undocumented, so its shape is checked before it is trusted.
        let object = Unmanaged<CFTypeRef>.fromOpaque(rawItems).takeUnretainedValue()
        guard CFGetTypeID(object) == CFArrayGetTypeID() else { return nil }
        let items = unsafeDowncast(object, to: CFArray.self)
        return (0..<CFArrayGetCount(items)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(items, index) else { return nil }
            let item = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(item) == CFDictionaryGetTypeID() else { return nil }
            return unsafeDowncast(item, to: CFDictionary.self)
        }
    }

    func name(of channel: CFDictionary) -> String? {
        channelName(channel)?.takeUnretainedValue() as String?
    }

    func unit(of channel: CFDictionary) -> String? {
        unitLabel(channel)?.takeUnretainedValue() as String?
    }

    /// Nil for a channel of another format, for which the library answers with a large negative number.
    func value(of channel: CFDictionary) -> Int64? {
        let value = simpleValue(channel, nil)
        return value >= 0 ? value : nil
    }

    /// Empty for a channel of another format, for which the library reports a count of -1.
    func states(of channel: CFDictionary) -> [ClusterActivity.State] {
        let count = stateCount(channel)
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index in
            guard let name = stateName(channel, index)?.takeUnretainedValue() as String? else { return nil }
            let residency = stateResidency(channel, index)
            guard residency >= 0 else { return nil }
            return ClusterActivity.State(name: name.trimmingCharacters(in: .whitespaces), residency: residency)
        }
    }
}

/// PRIVATE INTERFACE. The frequency of each performance state, kept in the power manager's device tree
/// node under undocumented names. Checked on macOS 27.2 on an M2.
enum PowerManagerTables {
    /// Hands `body` a way to read tables by name. Nil if the node is missing or `body` found nothing.
    static func read<Result>(_ body: ((String) -> [Double]) -> Result?) -> Result? {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS,
                String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "pmgr"
            else { continue }
            func table(_ key: String) -> [Double] {
                let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)
                return (value?.takeRetainedValue() as? Data).map(frequencies(from:)) ?? []
            }
            return body(table)
        }
        return nil
    }

    /// Reads pairs of little-endian frequency and voltage into megahertz. Depending on the chip the
    /// frequency is stored in hertz or kilohertz, which the size of the number gives away.
    static func frequencies(from data: Data) -> [Double] {
        let count = data.count / 8
        return data.withUnsafeBytes { raw in
            (0..<count).map { index in
                let value = Double(raw.loadUnaligned(fromByteOffset: index * 8, as: UInt32.self))
                return value >= 100_000_000 ? value / 1_000_000 : value / 1_000
            }
        }
    }
}
