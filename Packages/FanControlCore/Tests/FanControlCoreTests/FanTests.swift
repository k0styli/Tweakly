import Foundation
import Testing

@testable import FanControlCore

private let limits = FanLimits(minimum: 1500, maximum: 4500)

private func curve(_ pairs: (Double, Double)...) -> FanCurve {
    FanCurve(points: pairs.map { FanCurvePoint(temperature: $0.0, percent: $0.1) })
}

@Suite struct FanCurveTests {
    @Test func belowTheFirstPointTheSystemKeepsTheFan() {
        #expect(curve((60, 0), (90, 100)).percent(at: 59) == nil)
    }

    @Test func aTemperatureBetweenPointsFallsOnTheLine() {
        #expect(curve((60, 0), (80, 100)).percent(at: 70) == 50)
        #expect(curve((60, 0), (80, 100)).percent(at: 60) == 0)
    }

    @Test func aboveTheLastPointItStaysThere() {
        #expect(curve((60, 10), (80, 70)).percent(at: 99) == 70)
        #expect(curve((60, 10), (80, 70)).percent(at: 80) == 70)
    }

    @Test func aBrokenTemperatureMeansNothing() {
        #expect(curve((60, 0), (80, 100)).percent(at: .nan) == nil)
    }

    /// Preferences can hold anything.
    @Test func whateverIsGivenBecomesACurve() {
        let tidied = curve((90, 50), (60, 80), (60.2, 10), (500, 200), (.nan, 1))
        #expect(tidied.points.map(\.temperature) == [60, 90, 100])
        #expect(tidied.points.map(\.percent) == [80, 80, 100])
    }

    /// Preferences can hold anything, and a curve that falls would slow a fan down as things get hotter.
    @Test func whatIsReadFromPreferencesIsTidiedLikeAnythingElse() throws {
        let json =
            #"{"points":[{"temperature":90,"percent":0},{"temperature":30,"percent":100},{"temperature":500,"percent":500}]}"#
        let read = try JSONDecoder().decode(FanCurve.self, from: Data(json.utf8))
        #expect(read == curve((90, 0), (30, 100), (500, 500)))
        #expect(read.points.map(\.temperature) == [30, 90, 100])
        #expect(read.points.map(\.percent) == [100, 100, 100])
    }

    @Test func aCurveSurvivesBeingSavedAndRead() throws {
        for preset in FanPreset.allCases {
            let saved = try JSONEncoder().encode(preset.curve)
            #expect(try JSONDecoder().decode(FanCurve.self, from: saved) == preset.curve)
        }
    }

    @Test func oneOrNoPointsIsNotACurve() {
        #expect(curve((60, 0)).isUsable == false)
        #expect(FanCurve(points: []).isUsable == false)
        #expect(curve((60, 0), (70, 10)).isUsable)
    }

    @Test func aPointStaysBetweenItsNeighbours() {
        var moved = curve((50, 10), (70, 50), (90, 80))
        moved.move(pointAt: 1, to: FanCurvePoint(temperature: 200, percent: 200))
        #expect(moved.points[1] == FanCurvePoint(temperature: 89, percent: 80))
        moved.move(pointAt: 1, to: FanCurvePoint(temperature: 0, percent: 0))
        #expect(moved.points[1] == FanCurvePoint(temperature: 51, percent: 10))
    }

    @Test func aMoveOfAPointThatIsNotThereDoesNothing() {
        var moved = curve((50, 10), (70, 50))
        moved.move(pointAt: 5, to: FanCurvePoint(temperature: 60, percent: 20))
        #expect(moved == curve((50, 10), (70, 50)))
    }

    @Test func anAddedPointGoesInOrderAndCannotMakeItFall() {
        var edited = curve((50, 20), (90, 80))
        #expect(edited.add(FanCurvePoint(temperature: 70, percent: 95)) == 1)
        #expect(edited.points[1] == FanCurvePoint(temperature: 70, percent: 80))
    }

    @Test func thereIsNoRoomOnTopOfAPointOrPastTheLimit() {
        var edited = curve((50, 20), (90, 80))
        #expect(edited.add(FanCurvePoint(temperature: 50.5, percent: 30)) == nil)
        for temperature in stride(from: 55.0, to: 85, by: 5).prefix(6) {
            edited.add(FanCurvePoint(temperature: temperature, percent: 50))
        }
        #expect(edited.points.count == FanCurve.mostPoints)
        #expect(edited.add(FanCurvePoint(temperature: 87, percent: 80)) == nil)
    }

    @Test func aCurveKeepsEnoughPoints() {
        var edited = curve((50, 20), (70, 50), (90, 80))
        edited.remove(pointAt: 1)
        #expect(edited.points.count == 2)
        edited.remove(pointAt: 0)
        #expect(edited.points.count == 2)
    }

    @Test(arguments: FanPreset.allCases) func everyPresetIsAGoodCurve(preset: FanPreset) {
        let points = preset.curve.points
        #expect(preset.curve.isUsable)
        #expect(points == points.sorted { $0.temperature < $1.temperature })
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.percent <= $1.percent })
    }
}

@Suite struct FanTargetsTests {
    @Test func eachFanHasItsOwnPlace() {
        var targets = FanTargets()
        #expect(targets.merged([0: 2000, 1: 3000], last: nil) == [2000, 3000])
        #expect(targets.merged([1: 3000, 0: FanTargets.system], last: nil) == [FanTargets.system, 3000])
    }

    /// The helper goes by position, so fan 1 moving up would give fan 0 its speed, and give fan 1 back to the system.
    @Test func aFanWithNoReadingKeepsItsPlaceAndWhatItWasDoing() {
        var targets = FanTargets()
        #expect(targets.merged([1: 3100], last: [2000, 3000]) == [2000, 3100])
        #expect(targets.merged([0: 2100], last: [2000, 3100]) == [2100, 3100])
    }

    @Test func aFanWithNoReadingAndNothingBeforeThatStaysWithTheSystem() {
        var targets = FanTargets()
        #expect(targets.merged([1: 3000], last: nil) == [FanTargets.system, 3000])
        #expect(targets.merged([:], last: nil) == [])
    }

    /// Nothing can tell how a fan is doing that cannot be read, so it does not stay on its last speed for good.
    @Test func aFanThatStaysUnreadGoesBack() {
        var targets = FanTargets()
        var last: [Double]? = [2000, 3000]
        for _ in 1..<FanTargets.missesAllowed {
            last = targets.merged([1: 3000], last: last)
            #expect(last == [2000, 3000])
        }
        #expect(targets.merged([1: 3000], last: last) == [FanTargets.system, 3000])
    }

    @Test func aReadingInBetweenStartsTheCountAgain() {
        var targets = FanTargets()
        var last: [Double]? = [2000, 3000]
        for _ in 0..<(FanTargets.missesAllowed * 3) {
            last = targets.merged([1: 3000], last: last)
            last = targets.merged([0: 2000, 1: 3000], last: last)
        }
        #expect(last == [2000, 3000])
    }
}

@Suite struct FanSettingsTests {
    @Test func aPercentOfTheRangeStartsAtTheSlowestSpeed() {
        #expect(limits.rpm(atPercent: 0) == 1500)
        #expect(limits.rpm(atPercent: 50) == 3000)
        #expect(limits.rpm(atPercent: 100) == 4500)
        #expect(limits.rpm(atPercent: 500) == 4500)
        #expect(limits.rpm(atPercent: -5) == 1500)
    }

    @Test func nothingTakesAFanUntilSomeoneChooses() {
        #expect(FanSettings().adapter.usesFans(count: 2) == false)
    }

    /// Otherwise the sensors would go on being read for nothing, every few seconds for as long as the Mac runs.
    @Test func separateFansAllLeftToTheSystemTakeNothing() {
        var plan = FanProfile.balanced.plan
        plan.isLinked = false
        plan.separate = [FanSetup(), FanSetup()]
        #expect(plan.usesFans(count: 8) == false)
        var taken = FanSetup()
        taken.mode = .fixed
        plan.separate[1] = taken
        #expect(plan.usesFans(count: 8))
    }

    @Test func separateFansThatWereNeverSetGoByTheSharedOne() {
        var plan = FanProfile.balanced.plan
        plan.isLinked = false
        #expect(plan.usesFans(count: 2))
    }

    @Test func linkedFansShareOneSetup() {
        var plan = FanPlan()
        var setup = FanSetup()
        setup.mode = .fixed
        plan.setSetup(setup, ofFan: 1, fanCount: 2)
        #expect(plan.setup(ofFan: 0).mode == .fixed)
        #expect(plan.setup(ofFan: 1).mode == .fixed)
    }

    @Test func separateFansStartFromTheSharedOneAndGoTheirOwnWay() {
        var plan = FanPlan()
        plan.shared.mode = .fixed
        plan.isLinked = false
        var setup = FanSetup()
        setup.mode = .curve
        plan.setSetup(setup, ofFan: 1, fanCount: 2)
        #expect(plan.setup(ofFan: 0).mode == .fixed)
        #expect(plan.setup(ofFan: 1).mode == .curve)
    }

    @Test func theBatteryUsesTheSamePlanUntilItHasOne() {
        var settings = FanSettings()
        settings.adapter.shared.mode = .fixed
        #expect(settings.plan(onBattery: true).shared.mode == .fixed)
        var quiet = FanPlan()
        quiet.shared.mode = .system
        settings.battery = quiet
        #expect(settings.plan(onBattery: true).shared.mode == .system)
        #expect(settings.plan(onBattery: false).shared.mode == .fixed)
    }

    @Test func aBrokenCurveLeavesTheFanToTheSystem() {
        var setup = FanSetup()
        setup.mode = .curve
        setup.curve = FanCurve(points: [])
        #expect(setup.validated.mode == .system)
    }

    @Test func tuningFromPreferencesStaysInRange() {
        var tuning = FanTuning()
        tuning.emergencyTemperature = 500
        tuning.fastestRise = .nan
        tuning.smallestChange = -1
        let valid = tuning.validated
        #expect(valid.emergencyTemperature == 105)
        #expect(valid.fastestRise == 500)
        #expect(valid.smallestChange == 0)
    }

    @Test(arguments: FanProfile.allCases) func everyProfileIsRecognized(profile: FanProfile) {
        #expect(FanSettings().profile(of: profile.plan) == .builtIn(profile))
    }

    @Test func aChangedProfileIsNoLongerThatProfile() {
        var plan = FanProfile.balanced.plan
        plan.shared.sensor = .gpu
        #expect(FanSettings().profile(of: plan) == nil)
    }

    @Test func aSavedProfileIsFoundAndGivesItsPlanBack() {
        var settings = FanSettings()
        var plan = FanProfile.balanced.plan
        plan.shared.sensor = .gpu
        settings.savedProfiles = [SavedFanProfile(id: "a", name: "Игры", plan: plan)]
        #expect(settings.profile(of: plan) == .saved("a"))
        #expect(settings.plan(of: .saved("a")) == plan)
        #expect(settings.plan(of: .saved("gone")) == nil)
    }

    /// The curve of a fan at a fixed speed cannot change what it does.
    @Test func whatIsNotInUseDoesNotMakeAPlanDifferent() {
        var plan = FanProfile.maximum.plan
        plan.shared.curve = FanPreset.quiet.curve
        #expect(FanSettings().profile(of: plan) == .builtIn(.maximum))
    }

    @Test func theMaximumIsTheFullRange() {
        #expect(FanProfile.maximum.plan.shared.fixedPercent == 100)
        #expect(FanProfile.maximum.plan.shared.mode == .fixed)
    }

    @Test func settingsSurviveBeingSaved() throws {
        var settings = FanSettings()
        settings.adapter.shared.mode = .curve
        settings.savedProfiles = [SavedFanProfile(id: "a", name: "Лето", plan: FanProfile.quiet.plan)]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(FanSettings.self, from: data) == settings)
    }
}

@Suite struct FanControllerTests {
    private func setup(_ mode: FanMode, curve shape: FanCurve = curve((60, 0), (80, 100)), fixed: Double = 50)
        -> FanSetup
    {
        var setup = FanSetup()
        setup.mode = mode
        setup.curve = shape
        setup.fixedPercent = fixed
        return setup
    }

    private func tuning(smoothing: Double = 0) -> FanTuning {
        var tuning = FanTuning()
        tuning.smoothingSeconds = smoothing
        return tuning
    }

    @Test func theSystemModeTouchesNothing() {
        var controller = FanController()
        #expect(
            controller.next(
                setup: setup(.system), tuning: tuning(), limits: limits, temperature: 99, current: 0, now: 0) == .system
        )
    }

    @Test func aFixedSpeedHoldsWhateverTheTemperature() {
        var controller = FanController()
        #expect(
            controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 40, current: 0, now: 0)
                == .rpm(3000))
    }

    @Test func aCurveLeavesACoolFanToTheSystem() {
        var controller = FanController()
        #expect(
            controller.next(setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 50, current: 0, now: 0)
                == .system)
    }

    /// The first command takes the curve's speed at once: a fan that stood still has nothing to rise gently from.
    @Test func aCurveTakesOverAtItsSpeedStraightAway() {
        var controller = FanController()
        #expect(
            controller.next(setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 70, current: 0, now: 0)
                == .rpm(3000))
    }

    @Test func aCurveLetsGoOnlyWellBelowWhereItStarted() {
        var controller = FanController()
        _ = controller.next(setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 61, current: 0, now: 0)
        let near = controller.next(
            setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 58, current: 1500, now: 3)
        #expect(near != .system)
        let below = controller.next(
            setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 56, current: 1500, now: 6)
        #expect(below == .system)
    }

    @Test func aRiseIsHeldToItsRate() {
        var controller = FanController()
        _ = controller.next(setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 60, current: 0, now: 0)
        let next = controller.next(
            setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 80, current: 1500, now: 2)
        #expect(next == .rpm(2500))
    }

    @Test func aFallIsGentlerThanARise() {
        var controller = FanController()
        _ = controller.next(setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 80, current: 0, now: 0)
        let next = controller.next(
            setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 60, current: 4500, now: 2)
        #expect(next == .rpm(4200))
    }

    @Test func aSmallChangeLeavesTheFanAlone() {
        var controller = FanController()
        _ = controller.next(setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 70, current: 0, now: 0)
        let next = controller.next(
            setup: setup(.curve), tuning: tuning(), limits: limits, temperature: 70.2, current: 3000, now: 2)
        #expect(next == .rpm(3000))
    }

    @Test func aShortSpikeDoesNotReachTheFanWhenSmoothed() {
        var controller = FanController()
        _ = controller.next(
            setup: setup(.curve), tuning: tuning(smoothing: 10), limits: limits, temperature: 65, current: 0, now: 0)
        let next = controller.next(
            setup: setup(.curve), tuning: tuning(smoothing: 10), limits: limits, temperature: 85, current: 2250, now: 1)
        // The temperature counts as 67, a tenth of the way, so the speed moves towards 2550 and no further.
        guard case .rpm(let rpm) = next else {
            Issue.record("expected a speed")
            return
        }
        #expect(rpm < 2600)
    }

    /// Seen on an M1 Pro: one sensor jumped for a single reading under load, and the fans stopped for it.
    @Test func oneHotReadingIsNoEmergency() {
        var controller = FanController()
        #expect(
            controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 96, current: 0, now: 0)
                == .rpm(3000))
        #expect(controller.hold == nil)
        #expect(
            controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 60, current: 0, now: 3)
                == .rpm(3000))
        #expect(
            controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 96, current: 0, now: 6)
                == .rpm(3000))
    }

    @Test func anEmergencyRunsTheFanFlatOutAndSaysSo() {
        var controller = FanController()
        _ = controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 96, current: 0, now: 0)
        #expect(
            controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 96, current: 0, now: 3)
                == .rpm(4500))
        #expect(controller.hold == .emergency)
    }

    @Test func anEmergencyLastsUntilWellBelowTheLineAndTheSpeedComesDownGently() {
        var controller = FanController()
        _ = controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 96, current: 0, now: 0)
        _ = controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 96, current: 0, now: 1)
        #expect(
            controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 90, current: 0, now: 2)
                == .rpm(4500))
        #expect(controller.hold == .emergency)
        #expect(
            controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 87, current: 0, now: 3)
                == .rpm(4350))
        #expect(controller.hold == nil)
    }

    /// A curve that follows the battery would otherwise sleep through a processor at 96 °C.
    @Test func anEmergencyWatchesTheHottestNotWhatIsFollowed() {
        var controller = FanController()
        let cool = setup(.curve)
        #expect(
            controller.next(
                setup: cool, tuning: tuning(), limits: limits, temperature: 30, hottest: 96, current: 0, now: 0)
                == .system)
        #expect(
            controller.next(
                setup: cool, tuning: tuning(), limits: limits, temperature: 30, hottest: 96, current: 0, now: 3)
                == .rpm(4500))
        #expect(controller.hold == .emergency)
    }

    /// The graphics' sensors say nothing while that block is off. That must not hide a processor at 96 °C, as the system
    /// taking the fan back first stops it, see 0023.
    @Test func anEmergencyDoesNotWaitForWhatIsFollowed() {
        var controller = FanController()
        var commands: [FanCommand] = []
        for second in 0..<12 {
            commands.append(
                controller.next(
                    setup: setup(.curve), tuning: tuning(), limits: limits, temperature: nil, hottest: 96, current: 0,
                    now: Double(second) * 3))
        }
        #expect(commands[0] == .system)
        #expect(commands[1...].allSatisfy { $0 == .rpm(4500) })
        #expect(controller.hold == .emergency)
    }

    @Test func anEmergencyEndsAsUsualWhenWhatIsFollowedStaysSilent() {
        var controller = FanController()
        for second in 0..<3 {
            _ = controller.next(
                setup: setup(.curve), tuning: tuning(), limits: limits, temperature: nil, hottest: 96, current: 0,
                now: Double(second) * 3)
        }
        #expect(
            controller.next(
                setup: setup(.curve), tuning: tuning(), limits: limits, temperature: nil, hottest: 80, current: 4500,
                now: 9) == .rpm(4500))
        #expect(controller.hold == nil)
    }

    /// Nothing can be watched at all, so full speed has no reason to last, and the system has to look after the Mac.
    @Test func anEmergencyWithNoTemperatureAtAllGivesTheFanBack() {
        var controller = FanController()
        for second in 0..<2 {
            _ = controller.next(
                setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 96, current: 0,
                now: Double(second) * 3)
        }
        #expect(controller.hold == .emergency)
        var last = FanCommand.rpm(0)
        for second in 2..<(2 + FanController.failuresAllowed) {
            last = controller.next(
                setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: nil, current: 4500,
                now: Double(second) * 3)
        }
        #expect(last == .system)
        #expect(controller.hold == .noTemperature)
    }

    /// A curve following a block that is off gives the fan back after a while, and the chip can get hot after that.
    @Test func anEmergencyStillComesAfterTheFanWentBackForLackOfAReading() {
        var controller = FanController()
        var second = 0
        func next(hottest: Double) -> FanCommand {
            second += 3
            return controller.next(
                setup: setup(.curve), tuning: tuning(), limits: limits, temperature: nil, hottest: hottest, current: 0,
                now: Double(second))
        }
        for _ in 0..<(FanController.failuresAllowed + 3) { _ = next(hottest: 50) }
        #expect(controller.hold == .noTemperature)
        #expect(next(hottest: 96) == .system)
        #expect(next(hottest: 96) == .rpm(4500))
        #expect(controller.hold == .emergency)
    }

    /// A fixed speed follows nothing, and a sensor left chosen from when it had a curve is no reason to stop it.
    @Test func aFixedSpeedDoesNotNeedItsOwnSensor() {
        var controller = FanController()
        for second in 0..<12 {
            #expect(
                controller.next(
                    setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: nil, hottest: 60,
                    current: 3000,
                    now: Double(second) * 3) == .rpm(3000))
        }
        #expect(controller.hold == nil)
    }

    @Test func aCurveWhoseSensorStaysSilentStillGivesTheFanBack() {
        var controller = FanController()
        var last = FanCommand.rpm(0)
        for second in 0..<FanController.failuresAllowed {
            last = controller.next(
                setup: setup(.curve), tuning: tuning(), limits: limits, temperature: nil, hottest: 60, current: 3000,
                now: Double(second) * 3)
        }
        #expect(last == .system)
        #expect(controller.hold == .noTemperature)
    }

    /// The window read this reading by reading, so it said so for three seconds out of every fifteen.
    @Test func itGoesOnSayingThereIsNoTemperatureUntilOneReturns() {
        var controller = FanController()
        func next(_ temperature: Double?, at second: Int) -> FanCommand {
            controller.next(
                setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: temperature, current: 3000,
                now: Double(second) * 3)
        }
        for second in 0..<FanController.failuresAllowed { _ = next(nil, at: second) }
        for second in 0..<12 {
            #expect(next(nil, at: 10 + second) == .system)
            #expect(controller.hold == .noTemperature)
        }
        #expect(next(60, at: 30) == .rpm(3000))
        #expect(controller.hold == nil)
    }

    @Test func theSystemModeHasNoEmergencyOfItsOwn() {
        var controller = FanController()
        for second in 0..<3 {
            #expect(
                controller.next(
                    setup: setup(.system), tuning: tuning(), limits: limits, temperature: 99, current: 0,
                    now: Double(second)) == .system)
        }
        #expect(controller.hold == nil)
    }

    @Test func oneMissedReadingChangesNothing() {
        var controller = FanController()
        _ = controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 70, current: 0, now: 0)
        #expect(
            controller.next(
                setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: nil, current: 3000, now: 1)
                == .rpm(3000))
        #expect(controller.hold == nil)
    }

    @Test func noTemperatureForAWhileGivesTheFanBackAndSaysSo() {
        var controller = FanController()
        _ = controller.next(setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: 70, current: 0, now: 0)
        var last = FanCommand.rpm(0)
        for second in 1...FanController.failuresAllowed {
            last = controller.next(
                setup: setup(.fixed), tuning: tuning(), limits: limits, temperature: nil, current: 3000,
                now: Double(second))
        }
        #expect(last == .system)
        #expect(controller.hold == .noTemperature)
    }

    @Test func unusableLimitsMeanTheSystem() {
        var controller = FanController()
        let broken = FanLimits(minimum: 3000, maximum: 1000)
        #expect(
            controller.next(setup: setup(.fixed), tuning: tuning(), limits: broken, temperature: 60, current: 0, now: 0)
                == .system)
    }

    @Test func aSpeedNeverLeavesTheLimits() {
        var controller = FanController()
        #expect(
            controller.next(
                setup: setup(.fixed, fixed: 900), tuning: tuning(), limits: limits, temperature: 60, current: 0, now: 0)
                == .rpm(4500))
    }
}

@Suite struct FanHelperNamingTests {
    @Test func eachCopyOfTheAppHasItsOwnHelperFile() {
        #expect(
            FanHelper.launchdPlist(forApp: "me.tweakly.Tweakly")
                == "/Library/LaunchDaemons/me.tweakly.Tweakly.fanhelper.plist")
        #expect(
            FanHelper.launchdPlist(forApp: "me.tweakly.Tweakly.quiet")
                != FanHelper.launchdPlist(forApp: "me.tweakly.Tweakly"))
    }
}

@Suite struct HelperInstallScriptTests {
    private let manager = FileManager.default

    private func folder() throws -> String {
        let path = manager.temporaryDirectory.appending(path: "helper-install-\(UUID().uuidString)").path
        try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func run(_ script: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func inode(_ path: String) throws -> UInt64 {
        try (manager.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    /// An Apple-signed tool stands in for the helper, so the signature check has something real to check.
    private func script(in root: String, requirement: String?) -> String {
        HelperInstallScript.install(
            bundledTool: "/usr/bin/true", toolPath: root + "/Tools/helper", plistPath: root + "/helper.plist",
            plist: "<plist/>", label: "me.tweakly.test.fanhelper", requirement: requirement,
            owner: "\(getuid()):\(getgid())", launchd: false)
    }

    @Test func aHelperInstalledAgainIsANewFileNotTheOldOneRewritten() throws {
        let root = try folder()
        defer { try? manager.removeItem(atPath: root) }
        #expect(try run(script(in: root, requirement: "anchor apple")) == 0)
        let first = try inode(root + "/Tools/helper")
        #expect(try run(script(in: root, requirement: "anchor apple")) == 0)
        // The kernel keeps a signature per file: rewriting the same file in place is what got the new helper killed.
        #expect(try inode(root + "/Tools/helper") != first)
        #expect(!manager.fileExists(atPath: root + "/Tools/helper.new"))
        #expect(try String(contentsOfFile: root + "/helper.plist", encoding: .utf8) == "<plist/>\n")
        let mode = try manager.attributesOfItem(atPath: root + "/Tools/helper")[.posixPermissions] as? Int
        #expect(mode == 0o544)
    }

    @Test func aHelperSignedBySomeoneElseIsNotInstalled() throws {
        let root = try folder()
        defer { try? manager.removeItem(atPath: root) }
        #expect(try run(script(in: root, requirement: "anchor apple")) == 0)
        let installed = try inode(root + "/Tools/helper")
        let other = HelperInstallScript.signerRequirement(team: "ZZZZZZZZZZ", leafCertificateSHA1: nil)
        #expect(try run(script(in: root, requirement: other)) == 65)
        #expect(try inode(root + "/Tools/helper") == installed)
        #expect(!manager.fileExists(atPath: root + "/Tools/helper.new"))
    }

    @Test func theRequirementFollowsHowTheAppIsSigned() {
        let team = HelperInstallScript.signerRequirement(team: "ABCDE12345", leafCertificateSHA1: "ff")
        #expect(
            team?.hasPrefix("anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists") == true)
        #expect(team?.hasSuffix("certificate leaf[subject.OU] = \"ABCDE12345\"") == true)
        #expect(
            HelperInstallScript.signerRequirement(team: nil, leafCertificateSHA1: "0a1b")
                == "certificate leaf = H\"0a1b\"")
        #expect(HelperInstallScript.signerRequirement(team: "", leafCertificateSHA1: nil) == nil)
    }

    @Test func pathsWithQuotesStayOneWord() {
        let script = HelperInstallScript.install(
            bundledTool: "/Apps/it's/helper", toolPath: "/x/t", plistPath: "/x/p", plist: "", label: "l",
            requirement: nil)
        #expect(script.contains("/bin/cp '/Apps/it'\\''s/helper' '/x/t.new'"))
        #expect(script.hasPrefix("/bin/launchctl bootout system/'l' 2>/dev/null"))
        #expect(script.hasSuffix("/bin/launchctl bootstrap system '/x/p'"))
    }
}
