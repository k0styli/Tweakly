import CoreAudio
import Foundation
import Testing

@testable import AudioMixerCore

@Suite struct AudioRuleTests {
    @Test func aStandardRuleIsForgotten() {
        var book = AudioRuleBook()
        book.set(AppAudioRule(volume: 0.5), for: "com.spotify.client")
        #expect(book.rule(for: "com.spotify.client").volume == 0.5)
        book.set(AppAudioRule(volume: 1.002), for: "com.spotify.client")
        #expect(book.rules.isEmpty)
        #expect(book.rule(for: "com.apple.Safari") == .standard)
    }

    @Test func mutingAndAnOutputAreRulesToo() {
        #expect(!AppAudioRule(isMuted: true).isStandard)
        #expect(!AppAudioRule(outputUID: "BuiltInSpeakerDevice").isStandard)
        #expect(AppAudioRule(volume: 0.7, isMuted: true).gain == 0)
        #expect(AppAudioRule(volume: 1.5).gain == 1.5)
    }

    @Test func turningBoostingOffLowersEveryBoost() {
        var book = AudioRuleBook()
        book.set(AppAudioRule(volume: 1.8), for: "a")
        book.set(AppAudioRule(volume: 0.4), for: "b")
        book.limit(boosting: false)
        // Down to the app as it is, which is no rule at all.
        #expect(book.rules["a"] == nil)
        #expect(book.rule(for: "b").volume == 0.4)
        #expect(AudioRuleBook.highestVolume(boosting: true) == 2)
    }

    @Test func rulesSurviveBeingSaved() throws {
        var book = AudioRuleBook()
        book.set(AppAudioRule(volume: 0.3, isMuted: false, outputUID: "AirPods-UID"), for: "a")
        let copy = try JSONDecoder().decode(AudioRuleBook.self, from: JSONEncoder().encode(book))
        #expect(copy == book)
    }
}

@Suite struct DeviceKindTests {
    @Test func devicesAreToldApartAsTheSoundMenuShowsThem() {
        #expect(
            AudioDeviceKind.of(transport: "bltn", dataSource: "ispk", name: "MacBook Air Speakers", isInput: false)
                == .builtInSpeakers)
        #expect(
            AudioDeviceKind.of(transport: "bltn", dataSource: "hdpn", name: "External Headphones", isInput: false)
                == .builtInHeadphones)
        #expect(
            AudioDeviceKind.of(transport: "bltn", dataSource: nil, name: "MacBook Air Microphone", isInput: true)
                == .builtInMicrophone)
        #expect(
            AudioDeviceKind.of(transport: "blue", dataSource: nil, name: "AirPods Pro de Vx", isInput: false)
                == .airPodsPro)
        #expect(
            AudioDeviceKind.of(transport: "blue", dataSource: nil, name: "JBL Flip Speaker", isInput: false)
                == .bluetoothSpeaker)
        #expect(
            AudioDeviceKind.of(transport: "blue", dataSource: nil, name: "WH-1000XM5", isInput: false)
                == .bluetoothHeadphones)
        #expect(
            AudioDeviceKind.of(transport: "hdmi", dataSource: nil, name: "LG UltraFine", isInput: false) == .display)
        #expect(AudioDeviceKind.of(transport: "airp", dataSource: nil, name: "Living Room", isInput: false) == .airPlay)
        #expect(
            AudioDeviceKind.of(transport: "usb ", dataSource: nil, name: "USB Headset", isInput: false)
                == .usbHeadphones)
        #expect(AudioDeviceKind.builtInSpeakers.symbolName == "laptopcomputer")
    }

    @Test func codesReadAsFourLetters() {
        #expect(AudioDeviceKind.code(0x626C_746E) == "bltn")
        #expect(AudioDeviceKind.code(0x7573_6220) == "usb ")
    }
}

@Suite struct VolumeLevelTests {
    @Test func theSpeakerShowsAsManyWavesAsControlCenter() {
        #expect(VolumeLevel.waves(volume: 0, isMuted: false) == nil)
        #expect(VolumeLevel.waves(volume: 0.8, isMuted: true) == nil)
        #expect(VolumeLevel.waves(volume: 0.1, isMuted: false) == 1.0 / 3)
        #expect(VolumeLevel.waves(volume: 0.5, isMuted: false) == 2.0 / 3)
        #expect(VolumeLevel.waves(volume: 1, isMuted: false) == 1)
    }

    @Test func theOutputsSliderStopsOnTheKeysSteps() {
        // Seven presses show as 44 %, eight as 50 %, as in the system's own volume display.
        #expect(VolumeLevel.onStep(0.45) == 0.4375 && VolumeLevel.percent(0.4375) == 44)
        #expect(VolumeLevel.onStep(0.48) == 0.5)
        #expect(VolumeLevel.onStep(0.02) == 0 && VolumeLevel.onStep(0.99) == 1)
        #expect(VolumeLevel.onStep(1.3) == 1)
    }

    @Test func aScrollMovesByTheKeyboardsSteps() {
        #expect(VolumeLevel.stepped(0.5, by: 1) == 0.5625)
        #expect(VolumeLevel.stepped(0.51, by: -2) == 0.375)
        #expect(VolumeLevel.stepped(0.97, by: 3) == 1)
        #expect(VolumeLevel.stepped(0.02, by: -1) == 0)
        #expect(VolumeLevel.percent(0.5625) == 56)
    }
}

@Suite struct GroupingTests {
    let safari = AudioOwner(bundleID: "com.apple.Safari", name: "Safari", pid: 100)
    let music = AudioOwner(bundleID: "com.apple.Music", name: "Music", pid: 200)

    @Test func helpersPlayUnderTheirApp() {
        let clients = [
            AudioClient(objectID: 1, pid: 300, isPlaying: true),  // Safari's WebKit GPU process
            AudioClient(objectID: 2, pid: 100, isPlaying: false),
            AudioClient(objectID: 3, pid: 200, isPlaying: false),
            AudioClient(objectID: 4, pid: 50, isPlaying: true),  // a daemon with no app
        ]
        let owners: [Int32: AudioOwner] = [300: safari, 100: safari, 200: music]
        let apps = AudioAppGrouping.apps(clients: clients) { owners[$0.pid] }
        #expect(apps.map(\.id) == ["com.apple.Safari", "com.apple.Music"])
        #expect(apps[0].objectIDs == [1, 2] && apps[0].isPlaying)
        #expect(!apps[1].isPlaying)
    }

    @Test func rowsStayWhereTheyAreWhileThePopoverIsOpen() {
        let zoom = AudioOwner(bundleID: "us.zoom.xos", name: "Zoom", pid: 400)
        let apps = [
            MixerApp(owner: zoom, objectIDs: [5], isPlaying: true),
            MixerApp(owner: safari, objectIDs: [1], isPlaying: false),
            MixerApp(owner: music, objectIDs: [3], isPlaying: true),
        ]
        // Safari stopped but was shown, Music plays and is new, Zoom plays and is new.
        let shown = AudioAppGrouping.shown(apps, ruled: [], alreadyShown: ["com.apple.Safari"])
        #expect(shown.map(\.id) == ["com.apple.Safari", "com.apple.Music", "us.zoom.xos"])
        // A quiet app with a rule of its own is shown too.
        let quiet = [MixerApp(owner: music, objectIDs: [3], isPlaying: false)]
        #expect(AudioAppGrouping.shown(quiet, ruled: ["com.apple.Music"], alreadyShown: []).count == 1)
        #expect(AudioAppGrouping.shown(quiet, ruled: [], alreadyShown: []).isEmpty)
    }
}

@Suite struct TapPlanTests {
    let safari = MixerApp(
        owner: AudioOwner(bundleID: "com.apple.Safari", name: "Safari", pid: 100), objectIDs: [7, 3], isPlaying: true)
    let music = MixerApp(
        owner: AudioOwner(bundleID: "com.apple.Music", name: "Music", pid: 200), objectIDs: [4], isPlaying: true)

    @Test func onlyAppsWithARuleAreTaken() {
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(volume: 0.25), for: "com.apple.Safari")
        let groups = TapPlan.groups(
            apps: [safari, music], rules: rules, active: ["com.apple.Safari", "com.apple.Music"],
            systemOutputUID: "Speakers", connectedOutputs: ["Speakers"])
        #expect(
            groups == [
                TapGroup(
                    outputUID: "Speakers", taps: [TapItem(bundleID: "com.apple.Safari", objectIDs: [3, 7], gain: 0.25)])
            ])
    }

    @Test func anAppGoesToItsOwnOutputWhileItIsConnected() {
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(outputUID: "AirPods"), for: "com.apple.Music")
        rules.set(AppAudioRule(isMuted: true), for: "com.apple.Safari")
        let active: Set = ["com.apple.Safari", "com.apple.Music"]
        let both = TapPlan.groups(
            apps: [safari, music], rules: rules, active: active, systemOutputUID: "Speakers",
            connectedOutputs: ["Speakers", "AirPods"])
        #expect(both.map(\.outputUID) == ["Speakers", "AirPods"])
        #expect(both[0].taps[0].gain == 0)
        // Without its AirPods, Music at its own volume plays as macOS sends it, and needs no tap.
        let alone = TapPlan.groups(
            apps: [safari, music], rules: rules, active: active, systemOutputUID: "Speakers",
            connectedOutputs: ["Speakers"])
        #expect(alone.map(\.outputUID) == ["Speakers"] && alone[0].taps.count == 1)
    }

    @Test func aQuietAppKeepsItsTapForAWhile() {
        let now = Date(timeIntervalSince1970: 1000)
        let active = TapPlan.active(
            lastPlayed: ["a": now.addingTimeInterval(-10), "b": now.addingTimeInterval(-40)], playing: ["c"], now: now)
        #expect(active == ["a", "c"])
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(volume: 0.5), for: "com.apple.Music")
        #expect(
            TapPlan.groups(
                apps: [music], rules: rules, active: [], systemOutputUID: "Speakers", connectedOutputs: ["Speakers"]
            ).isEmpty)
    }

    @Test func aSliderCrossingFullVolumeKeepsTheGroupAsItIs() {
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(volume: 0.9), for: "com.apple.Safari")
        rules.set(AppAudioRule(volume: 0.2), for: "com.apple.Music")
        let active: Set = ["com.apple.Safari", "com.apple.Music"]
        let before = TapPlan.groups(
            apps: [safari, music], rules: rules, active: active, systemOutputUID: "Speakers",
            connectedOutputs: ["Speakers"])
        // At 100 % Safari's rule goes, but held it stays in the group at its own volume: only gains change.
        rules.set(.standard, for: "com.apple.Safari")
        let held = TapPlan.groups(
            apps: [safari, music], rules: rules, active: active, systemOutputUID: "Speakers",
            connectedOutputs: ["Speakers"], holding: ["com.apple.Safari"])
        #expect(held.count == 1 && held[0].hasSameSound(as: before[0]))
        #expect(held[0].taps.first { $0.bundleID == "com.apple.Safari" }?.gain == 1)
        // Once the hold is over it leaves the group.
        let after = TapPlan.groups(
            apps: [safari, music], rules: rules, active: active, systemOutputUID: "Speakers",
            connectedOutputs: ["Speakers"])
        #expect(after[0].taps.map(\.bundleID) == ["com.apple.Music"])
    }

    @Test func anAppKeepsItsTapForAWhileAfterALongPlay() {
        let start = Date(timeIntervalSince1970: 0)
        // Ten minutes of play with nothing to look at in between, then a pause.
        var heard = TapPlan.heard(lastPlayed: [:], wasPlaying: [], playing: ["music"], now: start)
        let paused = start.addingTimeInterval(600)
        heard = TapPlan.heard(lastPlayed: heard, wasPlaying: ["music"], playing: [], now: paused)
        #expect(TapPlan.active(lastPlayed: heard, playing: [], now: paused.addingTimeInterval(29)) == ["music"])
        #expect(TapPlan.active(lastPlayed: heard, playing: [], now: paused.addingTimeInterval(31)).isEmpty)
    }

    @Test func anAppStaysOnTheOutputItChoseForItself() {
        let call = MixerApp(
            owner: AudioOwner(bundleID: "us.zoom.xos", name: "zoom.us", pid: 7), objectIDs: [70], isPlaying: true,
            outputUID: "Headset")
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(volume: 0.8), for: "us.zoom.xos")
        let groups = TapPlan.groups(
            apps: [call], rules: rules, active: ["us.zoom.xos"], systemOutputUID: "Speakers",
            connectedOutputs: ["Speakers", "Headset"])
        #expect(groups.map(\.outputUID) == ["Headset"])
        // Sent to the output it plays on anyway, at its own volume, it needs no tap at all.
        rules.set(AppAudioRule(volume: 1, outputUID: "Headset"), for: "us.zoom.xos")
        #expect(
            TapPlan.groups(
                apps: [call], rules: rules, active: ["us.zoom.xos"], systemOutputUID: "Speakers",
                connectedOutputs: ["Speakers", "Headset"]
            ).isEmpty)
    }

    @Test func aPlayingProcessSaysWhereItsAppPlays() {
        let owner = AudioOwner(bundleID: "com.apple.Safari", name: "Safari", pid: 1)
        let apps = AudioAppGrouping.apps(
            clients: [
                AudioClient(objectID: 1, pid: 1, isPlaying: false, outputUID: "Speakers"),
                AudioClient(objectID: 2, pid: 2, isPlaying: true, outputUID: "AirPods"),
                AudioClient(objectID: 3, pid: 3, isPlaying: false, outputUID: "Display"),
            ], owner: { _ in owner })
        #expect(apps.count == 1 && apps[0].outputUID == "AirPods" && apps[0].isPlaying)
    }

    @Test func storedValuesNeverMakeAWildGain() {
        #expect(AppAudioRule(volume: 50).gain == 2)
        #expect(AppAudioRule(volume: -1).gain == 0)
        #expect(AppAudioRule(volume: .nan).gain == 0)
        #expect(VolumeLevel.percent(.nan) == 0 && VolumeLevel.percent(.infinity) == 0)
    }

    @Test func onlyTheGainChangingNeedsNothingBuilt() {
        let a = TapItem(bundleID: "x", objectIDs: [1, 2], gain: 0.5)
        #expect(a.hasSameSound(as: TapItem(bundleID: "x", objectIDs: [2, 1], gain: 0.9)))
        #expect(!a.hasSameSound(as: TapItem(bundleID: "x", objectIDs: [1], gain: 0.5)))
        let b = TapItem(bundleID: "y", objectIDs: [3], gain: 1.5)
        let group = TapGroup(outputUID: "Speakers", taps: [a, b])
        #expect(
            group.hasSameSound(
                as: TapGroup(outputUID: "Speakers", taps: [a, TapItem(bundleID: "y", objectIDs: [3], gain: 0)])))
        // Another app, one app fewer, or another output is another sound, built again.
        #expect(!group.hasSameSound(as: TapGroup(outputUID: "Speakers", taps: [a])))
        #expect(!group.hasSameSound(as: TapGroup(outputUID: "Speakers", taps: [b, a])))
        #expect(!group.hasSameSound(as: TapGroup(outputUID: "AirPods", taps: [a, b])))
    }
}

@Suite struct SignalTests {
    @Test func theLimiterLeavesQuietSoundAloneAndNeverClips() {
        #expect(SoftLimiter.limit(0.5) == 0.5)
        #expect(SoftLimiter.limit(-0.9) == -0.9)
        let loud = SoftLimiter.limit(1.6)
        #expect(loud > 0.9 && loud < 1)
        #expect(SoftLimiter.limit(-3) >= -1 && SoftLimiter.limit(30) <= 1)
        #expect(SoftLimiter.limit(1.2) < SoftLimiter.limit(1.4))
    }

    @Test func aGainMovesAcrossOneBuffer() {
        var ramp = GainRamp(0)
        let (start, step) = ramp.begin(towards: 1, frames: 4)
        #expect(start == 0.25 && step == 0.25)
        #expect(start + step * 3 == 1)
        #expect(ramp.current == 1)
        let steady = ramp.begin(towards: 1, frames: 4)
        #expect(steady.start == 1 && steady.step == 0)
    }
}

/// Runs the audio thread's mixing on buffers shaped as Core Audio hands them over.
@Suite struct TapMixerTests {
    /// A buffer list of `buffers`, each `channels` interleaved over `frames`, filled from `fill(buffer, sample)`.
    final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        init(_ shapes: [(channels: Int, frames: Int)], fill: (Int, Int) -> Float = { _, _ in 0 }) {
            // At least one buffer has to be allocated; an empty list just says it holds none.
            list = AudioBufferList.allocate(maximumBuffers: max(shapes.count, 1))
            list.count = shapes.count
            for (index, shape) in shapes.enumerated() {
                let count = shape.channels * shape.frames
                let data = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
                for sample in 0..<count { data[sample] = fill(index, sample) }
                storage.append(data)
                list[index] = AudioBuffer(
                    mNumberChannels: UInt32(shape.channels), mDataByteSize: UInt32(count * 4), mData: data)
            }
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }

        func samples(_ buffer: Int) -> [Float] {
            Array(UnsafeBufferPointer(start: storage[buffer], count: Int(list[buffer].mDataByteSize) / 4))
        }

        func render(_ mixer: TapMixer, into output: Buffers) {
            mixer.render(input: UnsafePointer(list.unsafePointer), output: output.list.unsafeMutablePointer)
        }
    }

    @Test func aStereoTapReachesAnInterleavedOutputAtItsGain() {
        let mixer = TapMixer(gains: [0.5], meters: true)
        // Left 0.4, right -0.2, four frames.
        let input = Buffers([(2, 4)]) { _, sample in sample % 2 == 0 ? 0.4 : -0.2 }
        let output = Buffers([(2, 4)]) { _, _ in 9 }
        input.render(mixer, into: output)
        #expect(output.samples(0) == [0.2, -0.1, 0.2, -0.1, 0.2, -0.1, 0.2, -0.1])
        #expect(abs(mixer.inputPeak - 0.4) < 1e-6 && abs(mixer.outputPeak - 0.2) < 1e-6)
    }

    @Test func twoBuffersOfOneChannelEachGetLeftAndRight() {
        let mixer = TapMixer(gains: [1])
        let input = Buffers([(2, 3)]) { _, sample in sample % 2 == 0 ? 0.3 : 0.6 }
        let output = Buffers([(1, 3), (1, 3)])
        input.render(mixer, into: output)
        #expect(output.samples(0) == [0.3, 0.3, 0.3])
        #expect(output.samples(1) == [0.6, 0.6, 0.6])
    }

    @Test func aSingleChannelOutputGetsBothSidesMixed() {
        let mixer = TapMixer(gains: [1])
        let input = Buffers([(2, 2)]) { _, sample in sample % 2 == 0 ? 0.2 : 0.4 }
        let output = Buffers([(1, 2)])
        input.render(mixer, into: output)
        #expect(output.samples(0).allSatisfy { abs($0 - 0.3) < 1e-6 })
    }

    @Test func theOutputsOwnInputStreamsAreSkipped() {
        // An output with a microphone of its own lists that stream first; its sound must never be played back.
        let mixer = TapMixer(gains: [1])
        let input = Buffers([(1, 2), (2, 2)]) { buffer, _ in buffer == 0 ? 0.9 : 0.1 }
        let output = Buffers([(2, 2)])
        input.render(mixer, into: output)
        #expect(output.samples(0).allSatisfy { abs($0 - 0.1) < 1e-6 })
    }

    @Test func tapsAddUpAndAreKeptFromClipping() {
        // Two boosted apps at 0.6 each come to 1.2, past full scale.
        let mixer = TapMixer(gains: [1.2, 1.2])
        let input = Buffers([(2, 2), (2, 2)]) { _, _ in 0.5 }
        let output = Buffers([(2, 2)])
        input.render(mixer, into: output)
        #expect(output.samples(0).allSatisfy { abs($0 - SoftLimiter.limit(1.2)) < 1e-6 && $0 < 1 })
    }

    @Test func aNewGainArrivesAcrossOneBufferWithoutAJump() {
        let mixer = TapMixer(gains: [0])
        mixer.gains.set(0, 1)
        let input = Buffers([(1, 4)]) { _, _ in 0.5 }
        let output = Buffers([(1, 4)])
        input.render(mixer, into: output)
        #expect(output.samples(0) == [0.125, 0.25, 0.375, 0.5])
        // The next buffer starts where the last one ended.
        let next = Buffers([(1, 4)])
        input.render(mixer, into: next)
        #expect(next.samples(0) == [0.5, 0.5, 0.5, 0.5])
    }

    @Test func missingOrShortBuffersPlaySilenceRatherThanReadPastTheEnd() {
        let mixer = TapMixer(gains: [1, 1])
        // The second tap's stream is missing, the first is shorter than the output.
        let input = Buffers([(2, 2)]) { _, _ in 0.25 }
        let output = Buffers([(2, 4)]) { _, _ in 7 }
        input.render(mixer, into: output)
        #expect(output.samples(0) == [0.25, 0.25, 0.25, 0.25, 0, 0, 0, 0])
        let empty = Buffers([])
        let silent = Buffers([(2, 4)]) { _, _ in 7 }
        empty.render(mixer, into: silent)
        #expect(silent.samples(0).allSatisfy { $0 == 0 })
    }

    @Test func oneAppAtFullVolumeIsLeftAsItIs() {
        // A loudly mastered song's peaks pass untouched while nothing is boosted or added up.
        let mixer = TapMixer(gains: [1])
        let input = Buffers([(1, 2)]) { _, _ in 0.97 }
        let output = Buffers([(1, 2)])
        input.render(mixer, into: output)
        #expect(output.samples(0) == [0.97, 0.97])
        // Not a number never reaches the speakers once the limiter is at work.
        #expect(SoftLimiter.limit(.nan) == 0 && SoftLimiter.limit(-.infinity) == 0)
    }

    @Test func aGainForATapThatDoesNotExistIsIgnored() {
        let board = GainBoard([1])
        board.set(3, 0.5)
        board.set(-1, 0.5)
        #expect(board.get(0) == 1 && board.count == 1)
    }
}
