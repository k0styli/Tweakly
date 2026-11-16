import Testing

@testable import AudioMixerCore

@Suite struct DeviceChoiceTests {
    private let builtIn = "BuiltInMicrophoneDevice"
    private let airPods = "AirPods-mic"
    private let usb = "USB-mic"

    @Test func airPodsDoNotTakeTheMicrophoneWhenAskedNotTo() {
        // macOS made the AirPods' microphone the input as they came: it goes back to the one in use before.
        let choice = AudioDeviceChoice.choice(
            connected: [builtIn, airPods], current: airPods, settled: builtIn, arrived: [airPods], order: nil,
            manualOnly: [airPods])
        #expect(choice == builtIn)
    }

    @Test func withoutTheSwitchMacOSsChoiceStands() {
        let choice = AudioDeviceChoice.choice(
            connected: [builtIn, airPods], current: airPods, settled: builtIn, arrived: [airPods], order: nil,
            manualOnly: [])
        #expect(choice == nil)
    }

    @Test func aMicrophonePluggedInIsStillTaken() {
        let choice = AudioDeviceChoice.choice(
            connected: [builtIn, usb, airPods], current: usb, settled: builtIn, arrived: [usb], order: nil,
            manualOnly: [airPods])
        #expect(choice == nil)
    }

    @Test func aChoiceMadeByHandStands() {
        // Nothing came: someone chose the AirPods' microphone themselves.
        let choice = AudioDeviceChoice.choice(
            connected: [builtIn, airPods], current: airPods, settled: builtIn, arrived: [], order: [builtIn, airPods],
            manualOnly: [airPods])
        #expect(choice == nil)
    }

    @Test func whenTheDeviceInUseGoesTheFirstInTheOrderTakesOver() {
        let choice = AudioDeviceChoice.choice(
            connected: ["speakers", "display", "airpods"], current: "display", settled: "usb", arrived: [],
            order: ["usb", "airpods", "speakers", "display"], manualOnly: [])
        #expect(choice == "airpods")
    }

    @Test func aDeviceLowerInTheOrderDoesNotTakeOver() {
        // macOS switched to the display's speakers as they came, but the person put them below the headphones.
        let choice = AudioDeviceChoice.choice(
            connected: ["headphones", "display"], current: "display", settled: "headphones", arrived: ["display"],
            order: ["headphones", "display"], manualOnly: [])
        #expect(choice == "headphones")
    }

    @Test func aDeviceHigherInTheOrderTakesOverEvenIfMacOSDidNot() {
        let choice = AudioDeviceChoice.choice(
            connected: ["speakers", "dock"], current: "speakers", settled: "speakers", arrived: ["dock"],
            order: ["dock", "speakers"], manualOnly: [])
        #expect(choice == "dock")
    }

    @Test func aDeviceChosenByHandStaysUntilABetterOneComes() {
        // The person picked the speakers over the headphones; a device below both comes and changes nothing.
        let choice = AudioDeviceChoice.choice(
            connected: ["headphones", "speakers", "display"], current: "speakers", settled: "speakers",
            arrived: ["display"], order: ["headphones", "speakers", "display"], manualOnly: [])
        #expect(choice == nil)
    }

    @Test func aHeadsetMicrophoneChosenByHandIsNotTakenAwayByAnyDeviceComing() {
        // The person picked the AirPods' microphone for a call; a webcam's microphone comes and macOS leaves it.
        let choice = AudioDeviceChoice.choice(
            connected: [builtIn, airPods, usb], current: airPods, settled: airPods, arrived: [usb], order: nil,
            manualOnly: [airPods])
        #expect(choice == nil)
    }

    @Test func aMacWithOnlyAHeadsetMicrophoneKeepsIt() {
        let choice = AudioDeviceChoice.choice(
            connected: [airPods], current: airPods, settled: nil, arrived: [airPods], order: nil, manualOnly: [airPods])
        #expect(choice == nil)
    }

    @Test func theMicrophoneSwitchWinsOverTheOrder() {
        // Someone put the AirPods first, but the AirPods' microphone is still only chosen by hand.
        let choice = AudioDeviceChoice.choice(
            connected: [builtIn, airPods], current: airPods, settled: builtIn, arrived: [airPods],
            order: [airPods, builtIn], manualOnly: [airPods])
        #expect(choice == builtIn)
    }

    @Test func headsetMicrophonesAreToldApart() {
        #expect(AudioDeviceChoice.isHeadsetMicrophone(.airPodsPro))
        #expect(AudioDeviceChoice.isHeadsetMicrophone(.bluetoothHeadphones))
        #expect(!AudioDeviceChoice.isHeadsetMicrophone(.builtInMicrophone))
        #expect(!AudioDeviceChoice.isHeadsetMicrophone(.usb))
    }
}

@Suite struct DeviceLearningTests {
    private let speakers = KnownAudioDevice(uid: "speakers", name: "MacBook Air Speakers", kind: .builtInSpeakers)
    private let airPods = KnownAudioDevice(uid: "airpods", name: "AirPods Pro", kind: .airPodsPro)
    private let display = KnownAudioDevice(uid: "display", name: "Studio Display", kind: .display)

    @Test func aNewDeviceGoesWhereMacOSPutIt() {
        // New headphones macOS switched to come first; a display it did not switch to comes last.
        var list = AudioDeviceChoice.learning(
            [speakers], connected: [speakers, airPods], chosenBySystem: "airpods", isInput: false)
        #expect(list.map(\.uid) == ["airpods", "speakers"])
        list = AudioDeviceChoice.learning(
            list, connected: [speakers, airPods, display], chosenBySystem: "airpods", isInput: false)
        #expect(list.map(\.uid) == ["airpods", "speakers", "display"])
    }

    @Test func aHeadsetMicrophoneAlwaysGoesLast() {
        let mic = KnownAudioDevice(uid: "mic", name: "MacBook Air Microphone", kind: .builtInMicrophone)
        let list = AudioDeviceChoice.learning(
            [mic], connected: [mic, airPods], chosenBySystem: "airpods", isInput: true)
        #expect(list.map(\.uid) == ["mic", "airpods"])
    }

    @Test func aKnownDeviceKeepsItsPlaceUnderItsNewName() {
        var renamed = airPods
        renamed.name = "Anna’s AirPods Pro"
        let list = AudioDeviceChoice.learning(
            [speakers, airPods], connected: [renamed, speakers], chosenBySystem: "airpods", isInput: false)
        #expect(list.map(\.uid) == ["speakers", "airpods"])
        #expect(list[1].name == "Anna’s AirPods Pro")
    }

    @Test func theFirstOrderStartsFromTheDeviceInUse() {
        let mic = KnownAudioDevice(uid: "mic", name: "MacBook Air Microphone", kind: .builtInMicrophone)
        let usb = KnownAudioDevice(uid: "usb", name: "USB Microphone", kind: .usb)
        let list = AudioDeviceChoice.initial(connected: [airPods, mic, usb], current: "airpods", isInput: true)
        #expect(list.map(\.uid) == ["mic", "usb", "airpods"])
        let outputs = AudioDeviceChoice.initial(connected: [speakers, airPods], current: "airpods", isInput: false)
        #expect(outputs.map(\.uid) == ["airpods", "speakers"])
    }
}

@Suite struct EqualizerPlanTests {
    private func app(_ id: String, _ objects: [UInt32], playing: Bool = true, output: String? = nil) -> MixerApp {
        MixerApp(
            owner: AudioOwner(bundleID: id, name: id, pid: Int32(objects.first ?? 0)), objectIDs: objects,
            isPlaying: playing, outputUID: output)
    }

    @Test func anAppWithOnlyAnEqualizerIsTakenWhereItPlays() {
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(equalizer: EqualizerPreset.builtIn("rock")!.settings), for: "music")
        let groups = TapPlan.groups(
            apps: [app("music", [10])], rules: rules, active: ["music"], systemOutputUID: "speakers",
            connectedOutputs: ["speakers"])
        #expect(groups.count == 1)
        #expect(groups[0].outputUID == "speakers")
        #expect(groups[0].taps.first?.equalizer.presetID == "rock")
        #expect(groups[0].output == nil)
    }

    @Test func anOutputsEqualizerTakesItWholeOnlyWhileSomethingPlaysThere() {
        var rules = AudioRuleBook()
        rules.setEqualizer(EqualizerPreset.builtIn("pop")!.settings, forOutput: "speakers", name: "Speakers")
        let quiet = TapPlan.groups(
            apps: [], rules: rules, active: [], systemOutputUID: "speakers", connectedOutputs: ["speakers"],
            activeOutputs: [], ownObjectID: 5)
        #expect(quiet.isEmpty)
        let playing = TapPlan.groups(
            apps: [], rules: rules, active: [], systemOutputUID: "speakers", connectedOutputs: ["speakers"],
            activeOutputs: ["speakers"], ownObjectID: 5)
        #expect(playing.count == 1)
        #expect(playing[0].taps.isEmpty)
        #expect(playing[0].output?.excluded == [5])
        #expect(playing[0].output?.equalizer.presetID == "pop")
        let gone = TapPlan.groups(
            apps: [], rules: rules, active: [], systemOutputUID: "speakers", connectedOutputs: [],
            activeOutputs: ["speakers"], ownObjectID: 5)
        #expect(gone.isEmpty)
    }

    @Test func withoutKnowingItselfNoOutputIsTakenWhole() {
        var rules = AudioRuleBook()
        rules.setEqualizer(EqualizerPreset.builtIn("pop")!.settings, forOutput: "speakers", name: "Speakers")
        let groups = TapPlan.groups(
            apps: [], rules: rules, active: [], systemOutputUID: "speakers", connectedOutputs: ["speakers"],
            activeOutputs: ["speakers"], ownObjectID: nil)
        #expect(groups.isEmpty)
    }

    @Test func appsTakenApartAreLeftOutOfTheOutputsWholeSound() {
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(volume: 0.5), for: "safari")
        rules.set(AppAudioRule(outputUID: "headphones"), for: "zoom")
        rules.setEqualizer(EqualizerPreset.builtIn("pop")!.settings, forOutput: "speakers", name: "Speakers")
        let groups = TapPlan.groups(
            apps: [app("safari", [20, 21]), app("zoom", [30])], rules: rules, active: ["safari", "zoom"],
            systemOutputUID: "speakers", connectedOutputs: ["speakers", "headphones"],
            activeOutputs: ["speakers"], ownObjectID: 5)
        let speakers = groups.first { $0.outputUID == "speakers" }
        #expect(speakers?.taps.map(\.bundleID) == ["safari"])
        #expect(speakers?.output?.excluded == [5, 20, 21, 30])
        #expect(groups.contains { $0.outputUID == "headphones" && $0.output == nil })
    }

    @Test func onlyAppsPlayingOnAnOutputByThemselvesAreLeftOutOfIt() {
        // A call app that chose the headset by itself and was given a volume is taken apart there, and has nothing
        // to do with the speakers' whole sound.
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(volume: 0.5), for: "zoom")
        rules.setEqualizer(EqualizerPreset.builtIn("pop")!.settings, forOutput: "speakers", name: "Speakers")
        let groups = TapPlan.groups(
            apps: [app("zoom", [30], output: "headphones")], rules: rules, active: ["zoom"],
            systemOutputUID: "speakers", connectedOutputs: ["speakers", "headphones"], activeOutputs: ["speakers"],
            ownObjectID: 5)
        #expect(groups.first { $0.outputUID == "speakers" }?.output?.excluded == [5])
    }

    @Test func anAppSentToAnOutputGetsItsEqualizerEvenWithNothingElsePlayingThere() {
        var rules = AudioRuleBook()
        rules.set(AppAudioRule(outputUID: "airpods"), for: "spotify")
        rules.setEqualizer(EqualizerPreset.builtIn("rock")!.settings, forOutput: "airpods", name: "AirPods")
        let groups = TapPlan.groups(
            apps: [app("spotify", [40])], rules: rules, active: ["spotify"], systemOutputUID: "speakers",
            connectedOutputs: ["speakers", "airpods"], activeOutputs: ["speakers"], ownObjectID: 5)
        let airPods = groups.first { $0.outputUID == "airpods" }
        #expect(airPods?.taps.map(\.bundleID) == ["spotify"])
        #expect(airPods?.output?.equalizer.presetID == "rock")
    }

    @Test func anOutputGivenBackItsSoundStaysTakenForAMoment() {
        // A slider dragged through 0 dB makes the equalizer flat for an instant.
        let groups = TapPlan.groups(
            apps: [], rules: AudioRuleBook(), active: [], systemOutputUID: "speakers", connectedOutputs: ["speakers"],
            activeOutputs: ["speakers"], holdingOutputs: ["speakers"], ownObjectID: 5)
        #expect(groups.first?.output?.equalizer == .flat)
        #expect(groups.first?.output?.excluded == [5])
    }

    @Test func aNewEqualizerValueNeedsNothingBuilt() {
        let before = TapGroup(
            outputUID: "speakers", taps: [TapItem(bundleID: "a", objectIDs: [1], gain: 1)],
            output: OutputTap(excluded: [5, 1], equalizer: EqualizerPreset.builtIn("pop")!.settings))
        var after = before
        after.taps[0].equalizer = EqualizerPreset.builtIn("rock")!.settings
        after.output?.equalizer = EqualizerPreset.builtIn("jazz")!.settings
        #expect(after.hasSameSound(as: before))
        var excludingMore = before
        excludingMore.output?.excluded = [5, 1, 9]
        #expect(!excludingMore.hasSameSound(as: before))
        var withoutOutput = before
        withoutOutput.output = nil
        #expect(!withoutOutput.hasSameSound(as: before))
    }

    @Test func outputsArePlayingForOthersNotForThisProcess() {
        let clients = [
            AudioClient(objectID: 1, pid: 100, isPlaying: true, outputUID: nil),
            AudioClient(objectID: 2, pid: 200, isPlaying: true, outputUID: "headphones"),
            AudioClient(objectID: 3, pid: 300, isPlaying: false, outputUID: "display"),
            AudioClient(objectID: 4, pid: 999, isPlaying: true, outputUID: "speakers"),
        ]
        let playing = TapPlan.playingOutputs(clients: clients, systemOutputUID: "speakers", ownPID: 999)
        #expect(playing == ["speakers", "headphones"])
        // With the one app on the system's output quiet, only this process plays there, which does not count.
        let quieter = TapPlan.playingOutputs(
            clients: [clients[0]].map { AudioClient(objectID: $0.objectID, pid: $0.pid, isPlaying: false) }
                + clients.dropFirst(),
            systemOutputUID: "speakers", ownPID: 999)
        #expect(quieter == ["headphones"])
    }
}
