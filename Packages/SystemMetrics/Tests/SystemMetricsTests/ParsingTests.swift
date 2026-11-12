import AppKit
import Foundation
import Testing

@testable import SystemMetrics

@Suite struct GPUSensorTests {
    private func state(_ name: String, _ residency: Int64) -> ClusterActivity.State {
        ClusterActivity.State(name: name, residency: residency)
    }

    @Test func frequencyIsWeightedByTimeInEachState() {
        let states = [state("OFF", 1_000), state("P1", 1), state("P2", 3)]
        #expect(GPUSensorReader.averageFrequency(states: states, levels: [400, 800]) == 700)
    }

    @Test func frequencyIsUnknownWhileTheBlockIsOff() {
        #expect(GPUSensorReader.averageFrequency(states: [state("OFF", 1_000)], levels: [400]) == nil)
    }

    @Test func aStateTheTableDoesNotListDropsTheValue() {
        #expect(GPUSensorReader.averageFrequency(states: [state("P3", 5)], levels: [400, 800]) == nil)
        #expect(GPUSensorReader.averageFrequency(states: [state("P0", 5)], levels: [400, 800]) == nil)
        #expect(GPUSensorReader.averageFrequency(states: [state("TURBO", 5)], levels: [400, 800]) == nil)
    }

    @Test func aChipWithoutTheTableDoesNotTrap() {
        #expect(GPUSensorReader.averageFrequency(states: [state("P1", 5)], levels: []) == nil)
    }

    @Test func anUnlistedStateThatWasNeverUsedIsIgnored() {
        let states = [state("P9", 0), state("P1", 5)]
        #expect(GPUSensorReader.averageFrequency(states: states, levels: [400]) == 400)
    }

    @Test func activeShareIsTheTimeAboveTheLowestState() {
        #expect(GPUSensorReader.activeShare([state("VMIN", 75), state("V1", 25)]) == 0.25)
        #expect(GPUSensorReader.activeShare([state("VMIN", 100), state("V1", 0)]) == 0)
    }

    @Test func activeShareNeedsTheLowestStateAndSomeTime() {
        #expect(GPUSensorReader.activeShare([state("V1", 25)]) == nil)
        #expect(GPUSensorReader.activeShare([state("VMIN", 0), state("V1", 0)]) == nil)
        #expect(GPUSensorReader.activeShare([]) == nil)
    }
}

@Suite struct LatencyTests {
    @Test func noPacketsMeanNoFigures() {
        let latency = LatencyMonitor.statistics(from: [])
        #expect(latency.average == nil)
        #expect(latency.jitter == nil)
        #expect(latency.loss == nil)
    }

    @Test func lossCountsEveryPacketAndTheRestOnlyAnswers() {
        let latency = LatencyMonitor.statistics(from: [10, nil, 20, nil])
        #expect(latency.loss == 0.5)
        #expect(latency.average == 15)
        #expect(latency.jitter == 10)
    }

    @Test func everythingLostStillReportsTheLoss() {
        let latency = LatencyMonitor.statistics(from: [nil, nil])
        #expect(latency.loss == 1)
        #expect(latency.average == nil)
        #expect(latency.jitter == nil)
    }

    @Test func oneAnswerHasNoJitter() {
        let latency = LatencyMonitor.statistics(from: [12])
        #expect(latency.average == 12)
        #expect(latency.jitter == nil)
    }

    @Test func onlyTheLatestAnswersAreAveraged() {
        let history = [Double?](repeating: 1_000, count: 30) + [Double?](repeating: 10, count: 10)
        let latency = LatencyMonitor.statistics(from: history)
        #expect(latency.average == 10)
        #expect(latency.jitter == 0)
    }

    @Test func echoRequestCarriesItsSequenceAndAValidChecksum() {
        for sequence: UInt16 in [0, 1, 0x1234, 0xffff] {
            let packet = LatencyMonitor.echoRequest(sequence: sequence)
            #expect(packet[0] == 8)
            #expect(UInt16(packet[6]) << 8 | UInt16(packet[7]) == sequence)
            var sum: UInt32 = 0
            for index in stride(from: 0, to: packet.count, by: 2) {
                sum += UInt32(packet[index]) << 8 | UInt32(packet[index + 1])
            }
            while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
            #expect(sum == 0xffff)
        }
    }

    @Test func replyIsReadWithOrWithoutItsIPHeader() {
        let reply: [UInt8] = [0, 0, 0, 0, 0, 0, 0x12, 0x34]
        #expect(LatencyMonitor.sequence(ofReply: reply[...]) == 0x1234)
        let header: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        #expect(LatencyMonitor.sequence(ofReply: (header + reply)[...]) == 0x1234)
    }

    @Test func anythingButAnEchoReplyIsIgnored() {
        let request: [UInt8] = [8, 0, 0, 0, 0, 0, 0x12, 0x34]
        #expect(LatencyMonitor.sequence(ofReply: request[...]) == nil)
        #expect(LatencyMonitor.sequence(ofReply: [0, 0, 0][...]) == nil)
        #expect(LatencyMonitor.sequence(ofReply: [UInt8]()[...]) == nil)
        // An IP header with nothing behind it.
        let header: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        #expect(LatencyMonitor.sequence(ofReply: header[...]) == nil)
    }
}

@Suite struct PublicAddressTests {
    @Test func readsTheAddressAndCountry() {
        let parsed = PublicAddressReader.parse("fl=12\nip=203.0.113.7\nts=1.5\nloc=DE\nwarp=off\n")
        #expect(parsed == PublicAddress(address: "203.0.113.7", countryCode: "DE"))
    }

    @Test func readsAnIPv6Address() {
        #expect(PublicAddressReader.parse("ip=2001:db8::1\nloc=NL")?.address == "2001:db8::1")
    }

    @Test func theCountryIsOptional() {
        #expect(PublicAddressReader.parse("ip=203.0.113.7")?.countryCode == nil)
    }

    @Test func codesWithoutAFlagAreDropped() {
        for code in ["T1", "XX", "D", "DEU", "1A", "Ё1"] {
            let parsed = PublicAddressReader.parse("ip=203.0.113.7\nloc=\(code)")
            #expect(parsed?.address == "203.0.113.7")
            #expect(parsed?.countryCode == nil, "\(code)")
        }
    }

    /// A captive portal answers the request with its own page, which must not read as an address.
    @Test func aPageThatIsNotTheAnswerGivesNothing() {
        #expect(PublicAddressReader.parse("<html><a href=\"/login?ip=203.0.113.7\">Sign in</a></html>") == nil)
        #expect(PublicAddressReader.parse("") == nil)
        #expect(PublicAddressReader.parse("ip=") == nil)
    }
}

@Suite struct DriveHealthTests {
    private func log(
        warning: UInt8 = 0, kelvin: Int = 313, used: UInt8 = 3, unitsRead: UInt64 = 0, unitsWritten: UInt64 = 0
    ) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = warning
        bytes[1] = UInt8(kelvin & 255)
        bytes[2] = UInt8(kelvin >> 8)
        bytes[5] = used
        for index in 0..<8 {
            bytes[32 + index] = UInt8((unitsRead >> (8 * UInt64(index))) & 255)
            bytes[48 + index] = UInt8((unitsWritten >> (8 * UInt64(index))) & 255)
        }
        return bytes
    }

    @Test func readsTheFieldsTheStandardFixes() throws {
        let health = try #require(DriveHealthReader.health(fromLog: log(unitsRead: 2_000_000, unitsWritten: 300)))
        #expect(abs((health.temperature ?? 0) - 39.85) < 0.001)
        #expect(health.wear == 0.03)
        #expect(health.bytesRead == 1_024_000_000_000)
        #expect(health.bytesWritten == 153_600_000)
        #expect(health.hasWarning == false)
        #expect(health.model == nil)
    }

    @Test func aDriveMayReportMoreThanItsRatedLife() {
        #expect(DriveHealthReader.health(fromLog: log(used: 120))?.wear == 1.2)
    }

    @Test func anyCriticalFlagCountsAsAWarning() {
        #expect(DriveHealthReader.health(fromLog: log(warning: 4))?.hasWarning == true)
    }

    @Test func noTemperatureReadsAsNone() {
        #expect(DriveHealthReader.health(fromLog: log(kelvin: 0))?.temperature == nil)
    }

    @Test func aShortLogGivesNothing() {
        #expect(DriveHealthReader.health(fromLog: [UInt8](repeating: 0, count: 511)) == nil)
    }

    @Test func aHugeCounterDoesNotTrap() {
        #expect(DriveHealthReader.health(fromLog: log(unitsRead: .max)) != nil)
    }
}

@Suite struct SystemBatteryHealthTests {
    private func output(_ capacity: String) -> Data {
        Data(
            """
            {"SPPowerDataType":[{"_name":"AC"},
            {"sppower_battery_health_info":{"sppower_battery_health_maximum_capacity":"\(capacity)"}}]}
            """.utf8)
    }

    @Test func readsThePercentWhateverItsSpacing() {
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: output("92 %")) == 92)
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: output("92%")) == 92)
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: output("100\u{00A0}%")) == 100)
    }

    @Test func anythingElseIsNoAnswer() {
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: output("Normal")) == nil)
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: output("0 %")) == nil)
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: output("150 %")) == nil)
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: Data("not json".utf8)) == nil)
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: Data("{}".utf8)) == nil)
        #expect(SystemBatteryHealth.maximumCapacity(fromProfilerOutput: Data()) == nil)
    }
}

@Suite struct ProcessSourceTests {
    @Test func readsTheOwnerOfAGPUClient() throws {
        let owner = try #require(GPUProcessSampler.owner(fromCreator: "pid 415, WindowServer"))
        #expect(owner.pid == 415)
        #expect(owner.name == "WindowServer")
    }

    @Test func anythingElseHasNoOwner() {
        for creator in ["", "pid 0, kernel_task", "pid -1, x", "pid abc, x", "pid 415", "WindowServer"] {
            #expect(GPUProcessSampler.owner(fromCreator: creator) == nil, "\(creator)")
        }
    }

    @Test func readsTrafficFromTheToolsOutput() throws {
        let usage = NetworkProcessSampler.parse(
            """
            ,bytes_in,bytes_out,
            Claude Helper.27096,1975620,2226247,
            com.apple.WebKit.Networking.811,5,6,
            """)
        #expect(usage.count == 2)
        let helper = try #require(usage[27096])
        #expect(helper.name == "Claude Helper")
        #expect(helper.received == 1_975_620)
        #expect(helper.sent == 2_226_247)
        #expect(usage[811]?.name == "com.apple.WebKit.Networking")
    }

    @Test func linesItCannotReadAreSkipped() {
        let usage = NetworkProcessSampler.parse(
            """
            nopid,1,2,
            app.notapid,1,2,
            app.-4,1,2,
            app.0,1,2,
            app.12,lots,2,
            app.13,1
            """)
        #expect(usage.isEmpty)
        #expect(NetworkProcessSampler.parse("").isEmpty)
    }
}

@Suite struct SystemDefinedEventTests {
    @Test func theFieldHoldsWhatNSEventCallsTheSubtype() throws {
        for subtype in Int16(0)...Int16(40) {
            let event = try #require(
                NSEvent.otherEvent(
                    with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, subtype: subtype, data1: 0, data2: 0)?.cgEvent)
            #expect(SystemDefinedEvent.subtype(of: event) == Int(subtype))
        }
    }

    @Test func aKeyPressIsNotAnAuxiliaryKey() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        #expect(SystemDefinedEvent.subtype(of: event) != SystemDefinedEvent.auxiliaryKeysSubtype)
    }
}

@Suite struct PrivacyPreflightTests {
    @Test func tccdNumbersMapToAnswers() {
        #expect(PrivacyPreflight.answer(code: 0) == .allowed)
        #expect(PrivacyPreflight.answer(code: 1) == .denied)
        #expect(PrivacyPreflight.answer(code: 2) == .notAsked)
    }

    @Test func anUnknownNumberIsNotReadAsAnAnswer() {
        #expect(PrivacyPreflight.answer(code: 3) == nil)
        #expect(PrivacyPreflight.answer(code: -1) == nil)
    }

    @Test func askingNeverTraps() {
        // From a test the answer is the test runner's, which may be anything; only that it comes back matters.
        for service in PrivacyPreflight.Service.allCases {
            _ = PrivacyPreflight.answer(for: service)
        }
    }
}
