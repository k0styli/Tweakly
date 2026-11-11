import Testing

@testable import TaskManagerCore

private func key(_ pid: Int32, _ start: UInt64 = 1) -> ProcessKey { ProcessKey(pid: pid, start: start) }

private func usage(
    _ pid: Int32, _ name: String, parent: Int32 = 1, path: String? = nil, cpu: Double? = 0, memory: UInt64? = 0
) -> ProcessUsage {
    ProcessUsage(key: key(pid), parentPID: parent, name: name, path: path, cpu: cpu, memory: memory)
}

@Suite struct UsageTrackerTests {
    @Test func theFirstReadingShowsNothingUsedYet() {
        var tracker = UsageTracker()
        let first = tracker.update(
            [
                ProcessCounters(key: key(5), parentPID: 1, userID: 501, name: "a", cpuTime: 10, diskRead: 4),
                ProcessCounters(key: key(6), parentPID: 1, userID: 0, name: "root"),
            ], at: 100)
        #expect(first[0].cpu == 0)
        #expect(first[0].diskRate == 0)
        #expect(first[0].gpu == nil)
        #expect(first[0].cpuTime == 10.0 / 1_000_000_000)
        #expect(first[1].cpu == nil)
        #expect(first[1].diskRate == nil)
    }

    @Test func ratesComeFromTheDifferenceOverTime() {
        var tracker = UsageTracker()
        let start = ProcessCounters(
            key: key(5), parentPID: 1, userID: 501, name: "a", cpuTime: 0, memory: 7, diskRead: 100, diskWritten: 0,
            gpuTime: 0, receiveRate: 2_000)
        _ = tracker.update([start], at: 100)
        var later = start
        later.cpuTime = 1_000_000_000
        later.diskRead = 2_100
        later.gpuTime = 250_000_000
        let usages = tracker.update([later], at: 102)
        #expect(usages[0].cpu == 0.5)
        #expect(usages[0].diskReadRate == 1_000)
        #expect(usages[0].diskWriteRate == 0)
        #expect(usages[0].gpu == 0.125)
        #expect(usages[0].receiveRate == 2_000)
        #expect(usages[0].sendRate == nil)
        #expect(usages[0].memory == 7)
    }

    @Test func aNewProcessStartsAtZeroOnceTrackingHasBegun() {
        var tracker = UsageTracker()
        _ = tracker.update([], at: 100)
        let usages = tracker.update(
            [ProcessCounters(key: key(9), parentPID: 1, userID: 501, name: "new", cpuTime: 5_000_000_000)], at: 101)
        #expect(usages[0].cpu == 0)
    }

    @Test func aReusedProcessNumberIsANewProcess() {
        var tracker = UsageTracker()
        _ = tracker.update([ProcessCounters(key: key(9, 1), parentPID: 1, userID: 0, name: "old", cpuTime: 0)], at: 100)
        let usages = tracker.update(
            [ProcessCounters(key: key(9, 2), parentPID: 1, userID: 0, name: "new", cpuTime: 3_000_000_000)], at: 101)
        #expect(usages[0].cpu == 0)
    }

    @Test func aCounterGoingBackwardsCountsAsNothing() {
        var tracker = UsageTracker()
        _ = tracker.update([ProcessCounters(key: key(3), parentPID: 1, userID: 0, name: "a", gpuTime: 9_000)], at: 100)
        let usages = tracker.update(
            [ProcessCounters(key: key(3), parentPID: 1, userID: 0, name: "a", gpuTime: 10)], at: 101)
        #expect(usages[0].gpu == 0)
    }

    @Test func whatCannotBeReadStaysUnknown() {
        var tracker = UsageTracker()
        _ = tracker.update([ProcessCounters(key: key(3), parentPID: 1, userID: 0, name: "root")], at: 100)
        let usages = tracker.update([ProcessCounters(key: key(3), parentPID: 1, userID: 0, name: "root")], at: 101)
        #expect(usages[0].cpu == nil)
        #expect(usages[0].memory == nil)
        #expect(usages[0].diskRate == nil)
    }

    @Test func readingsTooCloseTogetherKeepTheEarlierBaseline() {
        var tracker = UsageTracker()
        let counters = { (time: UInt64) in
            [ProcessCounters(key: key(3), parentPID: 1, userID: 0, name: "a", cpuTime: time)]
        }
        _ = tracker.update(counters(0), at: 100)
        _ = tracker.update(counters(10_000_000), at: 100.01)
        let usages = tracker.update(counters(500_000_000), at: 101)
        #expect(usages[0].cpu == 0.5)
        // One too close to the last keeps showing what it found.
        let close = tracker.update(counters(600_000_000), at: 101.05)
        #expect(close[0].cpu == 0.5)
        #expect(close[0].diskRate == nil)
    }

    @Test func gpuShareNeverPassesAll() {
        var tracker = UsageTracker()
        _ = tracker.update([ProcessCounters(key: key(3), parentPID: 1, userID: 0, name: "a", gpuTime: 0)], at: 100)
        let usages = tracker.update(
            [ProcessCounters(key: key(3), parentPID: 1, userID: 0, name: "a", gpuTime: 3_000_000_000)], at: 101)
        #expect(usages[0].gpu == 1)
    }
}

@Suite struct GroupingTests {
    private let chrome = "/Applications/Google Chrome.app"

    private var apps: [Int32: AppIdentity] {
        [
            100: AppIdentity(pid: 100, name: "Google Chrome", bundlePath: chrome, isRegular: true),
            200: AppIdentity(
                pid: 200, name: "Terminal", bundlePath: "/System/Applications/Utilities/Terminal.app", isRegular: true),
            300: AppIdentity(pid: 300, name: "Tweakly", bundlePath: "/Applications/Tweakly.app", isRegular: false),
        ]
    }

    @Test func helpersStartedByAnAppJoinIt() {
        let processes = [
            usage(100, "Google Chrome", path: chrome + "/Contents/MacOS/Google Chrome"),
            usage(101, "Google Chrome Helper", parent: 100, cpu: 0.5),
            usage(102, "Google Chrome Helper (Renderer)", parent: 100, cpu: 0.25),
        ]
        let groups = ProcessGrouping.groups(of: processes, apps: apps)
        #expect(groups.count == 1)
        #expect(groups[0].members.map(\.pid).sorted() == [101, 102])
        #expect(groups[0].total.cpu == 0.75)
        #expect(groups[0].section == .apps)
    }

    @Test func grandchildrenJoinTheAppToo() {
        let processes = [
            usage(200, "Terminal"), usage(201, "login", parent: 200), usage(202, "zsh", parent: 201),
            usage(203, "claude", parent: 202),
        ]
        let groups = ProcessGrouping.groups(of: processes, apps: apps)
        #expect(groups.count == 1)
        #expect(groups[0].processCount == 4)
    }

    @Test func aProcessInsideTheBundleJoinsWhoeverStartedIt() {
        let processes = [
            usage(100, "Google Chrome"),
            usage(
                150, "chrome_crashpad_handler", parent: 1,
                path: chrome + "/Contents/Frameworks/x/chrome_crashpad_handler"),
        ]
        let groups = ProcessGrouping.groups(of: processes, apps: apps)
        #expect(groups.count == 1)
        #expect(groups[0].members.map(\.pid) == [150])
    }

    @Test func theResponsibleAppWins() {
        let processes = [usage(100, "Google Chrome"), usage(200, "Terminal"), usage(400, "Service", parent: 1)]
        let groups = ProcessGrouping.groups(of: processes, apps: apps, responsible: [400: 200])
        let terminal = groups.first { $0.head.pid == 200 }
        #expect(terminal?.members.map(\.pid) == [400])
    }

    @Test func installedAgentsAreBackgroundAndMacOSIsSystem() {
        var daemon = usage(50, "mds_stores", parent: 1, path: "/System/Library/Frameworks/x/mds_stores")
        daemon.userID = 0
        var tweakly = usage(300, "Tweakly", parent: 1, path: "/Applications/Tweakly.app/Contents/MacOS/Tweakly")
        tweakly.userID = 501
        var dock = usage(301, "Dock", parent: 1, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")
        dock.userID = 501
        var brew = usage(302, "redis-server", parent: 1, path: "/usr/local/bin/redis-server")
        brew.userID = 501
        let sections = Dictionary(
            uniqueKeysWithValues: ProcessGrouping.groups(of: [daemon, tweakly, dock, brew], apps: apps, user: 501)
                .map { ($0.head.pid, $0.section) })
        #expect(sections[50] == .system)
        #expect(sections[300] == .background)
        #expect(sections[301] == .system)
        #expect(sections[302] == .background)
    }

    @Test func aProcessWithNoPathIsTheSystems() {
        var kernel = usage(0, "kernel_task", parent: 0)
        kernel.userID = 0
        #expect(ProcessGrouping.isSystem(kernel, user: 501))
    }

    @Test func aHelperAppJoinsTheAppThatStartedIt() {
        var apps = apps
        apps[110] = AppIdentity(
            pid: 110, name: "Chrome Web Content", bundlePath: chrome + "/Contents/Helper.app", isRegular: false)
        let processes = [usage(100, "Google Chrome"), usage(110, "helper", parent: 100)]
        let groups = ProcessGrouping.groups(of: processes, apps: apps)
        #expect(groups.count == 1)
        #expect(groups[0].members.map(\.name) == ["Chrome Web Content"])
    }

    @Test func anAgentHeadsItsOwnHelpers() {
        var agent = usage(300, "Tweakly", path: "/Applications/Tweakly.app/Contents/MacOS/Tweakly")
        agent.userID = 501
        let processes = [agent, usage(301, "TweaklyHelper", parent: 300)]
        let groups = ProcessGrouping.groups(of: processes, apps: apps, user: 501)
        #expect(groups.count == 1)
        #expect(groups[0].section == .background)
        #expect(groups[0].members.map(\.pid) == [301])
    }

    @Test func aParentLoopEnds() {
        let processes = [usage(10, "a", parent: 11), usage(11, "b", parent: 10)]
        let groups = ProcessGrouping.groups(of: processes, apps: [:])
        #expect(groups.count == 2)
    }

    @Test func unknownValuesAddUpToUnknown() {
        let processes = [
            usage(100, "Google Chrome", cpu: nil, memory: nil), usage(101, "Helper", parent: 100, cpu: nil, memory: 5),
        ]
        let groups = ProcessGrouping.groups(of: processes, apps: apps)
        #expect(groups[0].total.cpu == nil)
        #expect(groups[0].total.memory == 5)
    }

    @Test func bundlePaths() {
        let helper =
            chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/"
            + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(ProcessGrouping.outermostBundle(of: helper) == chrome)
        #expect(ProcessGrouping.innermostBundle(of: helper)?.hasSuffix("Google Chrome Helper (Renderer).app") == true)
        #expect(ProcessGrouping.innermostBundle(of: "/usr/sbin/mDNSResponder") == nil)
        #expect(ProcessGrouping.outermostBundle(of: "/usr/libexec/logd") == nil)
        #expect(
            ProcessGrouping.outermostBundle(of: "/Applications/Ёжик.app/Contents/MacOS/Ёжик")
                == "/Applications/Ёжик.app")
        #expect(ProcessGrouping.outermostBundle(of: "/Applications/Only.app") == nil)
        #expect(ProcessGrouping.outermostBundle(of: ".app/x") == ".app")
        #expect(ProcessGrouping.outermostBundle(of: "/a.app/b.app/c") == "/a.app")
    }
}

@Suite struct ProcessTableTests {
    private var groups: [ProcessGroup] {
        [
            ProcessGroup(
                section: .apps, name: "Safari", head: usage(10, "Safari", cpu: 0.1),
                members: [usage(11, "Safari Web Content", parent: 10, cpu: 0.3)]),
            ProcessGroup(section: .apps, name: "Mail", head: usage(20, "Mail", cpu: 0.2), members: []),
            ProcessGroup(section: .background, name: "mds", head: usage(30, "mds", cpu: nil), members: []),
            ProcessGroup(section: .background, name: "logd", head: usage(31, "logd", cpu: 0.05), members: []),
        ]
    }

    @Test func theListOpensSortedByName() {
        #expect(TaskSort.standard == TaskSort(column: .name, ascending: true))
    }

    @Test func byNameTheListIsSplitIntoSections() {
        let table = ProcessTable(groups: groups, sort: .standard)
        #expect(
            table.rows == [
                .section(.apps), .group(key(20)), .group(key(10)), .section(.background), .group(key(31)),
                .group(key(30)),
            ])
        #expect(table.sectionPositions == [0, 3])
        #expect(table.count(in: .apps) == 2)
    }

    /// As in Windows: sorted by anything but the name, the busiest lead whatever kind of process they are.
    @Test func byLoadTheListIsOneWithTheBusiestFirst() {
        let table = ProcessTable(groups: groups, sort: .busiest)
        #expect(table.rows == [.group(key(10)), .group(key(20)), .group(key(31)), .group(key(30))])
        #expect(table.sectionPositions.isEmpty)
        #expect(table.count(in: .background) == 2)
        #expect(table.section(of: .group(key(31))) == .background)
    }

    @Test func onlyTheNameSplitsTheList() {
        for column in TaskColumn.allCases {
            let table = ProcessTable(groups: groups, sort: TaskSort(column: column, ascending: true))
            #expect(table.sectionPositions.isEmpty == (column != .name), "\(column)")
        }
    }

    @Test func byKindOneListStillPutsAppsFirst() {
        let table = ProcessTable(groups: groups, sort: TaskSort(column: .kind, ascending: true))
        #expect(table.rows.prefix(2).allSatisfy { table.section(of: $0) == .apps })
        #expect(table.rows.count == 4)
    }

    @Test func unknownValuesGoLastEitherWay() {
        let ascending = ProcessTable(groups: groups, sort: TaskSort(column: .cpu, ascending: true))
        #expect(ascending.rows.last == .group(key(30)))
    }

    @Test func anOpenGroupListsTheAppAndItsHelpers() {
        let table = ProcessTable(groups: groups, sort: .busiest, expanded: [key(10)])
        #expect(table.rows[1] == .member(group: key(10), key(11)))
        #expect(table.rows[2] == .member(group: key(10), key(10)))
        #expect(table.usage(of: .group(key(10)))?.cpu == 0.4)
        #expect(table.usage(of: table.rows[1])?.name == "Safari Web Content")
    }

    @Test func aGroupWithNoHelpersHasNothingToOpen() {
        let table = ProcessTable(groups: groups, sort: .busiest, expanded: [key(20)])
        #expect(table.rows.count == 4)
    }

    @Test func searchingForAHelperOpensItsGroup() {
        let table = ProcessTable(groups: groups, sort: .standard, query: "web")
        #expect(table.rows == [.section(.apps), .group(key(10)), .member(group: key(10), key(11))])
        #expect(table.openedBySearch == [key(10)])
    }

    @Test func searchingForAnAppShowsItClosed() {
        let table = ProcessTable(groups: groups, sort: .busiest, query: "saf")
        #expect(table.rows == [.group(key(10))])
    }

    @Test func aProcessNumberFindsItsProcess() {
        let table = ProcessTable(groups: groups, sort: .standard, query: "31")
        #expect(table.rows == [.section(.background), .group(key(31))])
    }

    @Test func sortingByNameIgnoresCaseAndReadsNumbers() {
        let named = [
            ProcessGroup(section: .background, name: "b10", head: usage(1, "b10"), members: []),
            ProcessGroup(section: .background, name: "B2", head: usage(2, "B2"), members: []),
            ProcessGroup(section: .background, name: "a", head: usage(3, "a"), members: []),
        ]
        let table = ProcessTable(groups: named, sort: TaskSort(column: .name, ascending: true))
        #expect(table.rows.dropFirst().map { table.usage(of: $0)?.name } == ["a", "B2", "b10"])
    }

    @Test func tiesKeepAStableOrder() {
        let even = [
            ProcessGroup(section: .background, name: "same", head: usage(7, "same"), members: []),
            ProcessGroup(section: .background, name: "same", head: usage(3, "same"), members: []),
        ]
        let table = ProcessTable(groups: even, sort: .busiest)
        #expect(table.rows == [.group(key(3)), .group(key(7))])
    }

    @Test func sortingByUserUsesNames() {
        var root = usage(1, "x")
        root.userID = 0
        var mine = usage(2, "y")
        mine.userID = 501
        let byUser = [
            ProcessGroup(section: .background, name: "x", head: root, members: []),
            ProcessGroup(section: .background, name: "y", head: mine, members: []),
        ]
        let table = ProcessTable(
            groups: byUser, sort: TaskSort(column: .user, ascending: true), userNames: [0: "root", 501: "anna"])
        #expect(table.rows == [.group(key(2)), .group(key(1))])
    }
}

@Suite struct FinderOrderTests {
    /// Names Finder's order treats in its own ways: case, numbers inside names, accents, punctuation and equal pairs.
    private static let names = [
        "Safari", "safari", "SAFARI", "b10", "B2", "b2", "a", "A", "ä", "é", "e", "Z", "zeta", "10", "9", "file 2",
        "file 10", "file-1", "_hidden", ".dot", "Ёж", "ёлка", "яблоко", "Google Chrome Helper (Renderer)",
        "Google Chrome Helper (GPU)", "Google Chrome", "com.apple.WebKit.WebContent", "mdworker_shared", "mds",
        "mds_stores", "kernel_task", "launchd", "", " ", "x1y2", "x1y10", "x01y2",
    ]

    private func groups(_ names: [String]) -> [ProcessGroup] {
        names.enumerated().map { index, name in
            var head = usage(Int32(index + 1), name)
            head.userID = UInt32(index % 4)
            return ProcessGroup(section: .background, name: name, head: head, members: [])
        }
    }

    @Test func sortingWithLearntNamesMatchesFinderOrder() {
        let all = groups(Self.names)
        let users: [UInt32: String] = [0: "root", 1: "Anna", 2: "anna", 3: "_spotlight"]
        var order = FinderOrder()
        order.learn(all, userNames: users)
        for sort in [
            TaskSort(column: .name, ascending: true), TaskSort(column: .name, ascending: false),
            TaskSort(column: .user, ascending: true), TaskSort(column: .user, ascending: false),
        ] {
            let plain = ProcessTable(groups: all, sort: sort, userNames: users)
            let ranked = ProcessTable(groups: all, sort: sort, userNames: users, names: order)
            #expect(plain.rows == ranked.rows)
        }
    }

    @Test func learningANameAtATimeMatchesLearningThemAll() {
        var atOnce = FinderOrder()
        atOnce.learn(Set(Self.names))
        var oneByOne = FinderOrder()
        var known: Set<String> = []
        for name in Self.names.shuffled() {
            known.insert(name)
            oneByOne.learn(known)
        }
        let ranks = { (order: FinderOrder) in Self.names.map { order.rank(of: $0) } }
        #expect(ranks(atOnce) == ranks(oneByOne))
        #expect(atOnce.rank(of: "B2")! < atOnce.rank(of: "b10")!)
    }

    @Test func everyColumnSortsAsComparingLinesOneByOneWould() {
        var generator = SystemRandomNumberGenerator()
        func maybe<T>(_ value: T) -> T? { Bool.random(using: &generator) ? value : nil }
        let names = Self.names
        let lines = (1...300).map { pid -> ProcessUsage in
            // Few distinct figures, so ties are common and the tie-breaks are exercised too.
            ProcessUsage(
                key: ProcessKey(pid: Int32(pid), start: UInt64.random(in: 0...2)), userID: UInt32.random(in: 0...3),
                name: names.randomElement()!, cpu: maybe(Double(Int.random(in: 0...3)) / 10),
                cpuTime: maybe(Double(Int.random(in: 0...3))), memory: maybe(UInt64.random(in: 0...3) * 1_000),
                diskReadRate: maybe(Double(Int.random(in: 0...2))), diskWriteRate: maybe(1), gpu: maybe(0.5),
                receiveRate: maybe(Double(Int.random(in: 0...2))), sendRate: maybe(2),
                threads: maybe(Int.random(in: 1...3)),
                isTranslated: maybe(Bool.random()))
        }
        let sections = lines.map { _ in ProcessSection.allCases.randomElement()! }
        let users: [UInt32: String] = [0: "root", 1: "Anna", 2: "anna", 3: "_spotlight"]
        var order = FinderOrder()
        order.learn(Set(names + users.values))
        for column in TaskColumn.allCases {
            for ascending in [true, false] {
                let sort = TaskSort(column: column, ascending: ascending)
                let ordering = Ordering(sort: sort, userNames: users, names: order)
                // Mixed kinds, as in the one list every sort but the name shows.
                let fast = ordering.sorted(Array(lines.indices), section: { sections[$0] }, by: { lines[$0] })
                let plain = Ordering(sort: sort, userNames: users)
                let slow = lines.indices.sorted {
                    plain.precedes(lines[$0], sections[$0], lines[$1], sections[$1])
                }
                #expect(fast == slow, "\(column) \(ascending ? "up" : "down")")
            }
        }
    }

    @Test func namesNoLongerInUseAreLetGo() {
        var order = FinderOrder()
        order.learn(Set((0..<200).map { "old \($0)" }))
        order.learn(["new"])
        #expect(order.rank(of: "old 1") == nil)
        #expect(order.rank(of: "new") == 0)
    }
}

@Suite struct LoadShadeTests {
    private func level(_ column: TaskColumn, _ usage: ProcessUsage) -> Int? {
        LoadShade.level(of: column, usage, coreCount: 8, totalMemory: 8_000_000_000)
    }

    @Test func nothingIsUnshaded() {
        let idle = ProcessUsage(key: key(1), name: "a", cpu: 0, memory: 0, diskReadRate: 0, gpu: 0, receiveRate: 0)
        for column in [TaskColumn.cpu, .memory, .disk, .network, .gpu] { #expect(level(column, idle) == 0) }
    }

    @Test func moreLoadMeansAStrongerShade() {
        let light = ProcessUsage(key: key(1), name: "a", cpu: 0.1)
        let heavy = ProcessUsage(key: key(1), name: "a", cpu: 2)
        let full = ProcessUsage(key: key(1), name: "a", cpu: 8)
        #expect(level(.cpu, light)! > 0)
        #expect(level(.cpu, light)! < level(.cpu, heavy)!)
        #expect(level(.cpu, full) == LoadShade.steps)
    }

    @Test func ratesGoByOrderOfMagnitude() {
        let kilobytes = ProcessUsage(key: key(1), name: "a", diskReadRate: 10_000)
        let megabytes = ProcessUsage(key: key(1), name: "a", diskReadRate: 5_000_000)
        let lots = ProcessUsage(key: key(1), name: "a", diskReadRate: 900_000_000)
        #expect(level(.disk, kilobytes)! < level(.disk, megabytes)!)
        #expect(level(.disk, lots) == LoadShade.steps)
    }

    @Test func otherColumnsAndUnknownFiguresAreNotShaded() {
        let unknown = ProcessUsage(key: key(1), name: "a")
        #expect(level(.cpu, unknown) == nil)
        #expect(level(.pid, ProcessUsage(key: key(1), name: "a", cpu: 1)) == nil)
    }
}

@Suite struct KeyShortcutTests {
    @Test func theStandardShortcutIsAllowed() {
        #expect(KeyShortcut.standard.problem() == nil)
        #expect(KeyShortcut.standard.modifierSymbols == "⌃⇧")
    }

    @Test func theSystemForceQuitStaysTheSystems() {
        #expect(KeyShortcut.forceQuitWindow.problem() == .forceQuitWindow)
    }

    @Test func aPlainKeyOrCommandAloneIsNotEnough() {
        #expect(KeyShortcut(keyCode: 0, modifiers: 0).problem() == .needsControlOrOption)
        #expect(KeyShortcut(keyCode: 0, modifiers: KeyShortcut.Modifier.command).problem() == .needsControlOrOption)
        #expect(
            KeyShortcut(keyCode: 0, modifiers: KeyShortcut.Modifier.command | KeyShortcut.Modifier.shift).problem()
                == .needsControlOrOption)
    }

    @Test func aFunctionKeyWorksAlone() {
        #expect(KeyShortcut(keyCode: 122, modifiers: 0).problem() == nil)
    }

    @Test func whatTheSystemUsesIsTaken() {
        let screenshot = KeyShortcut(
            keyCode: 21, modifiers: KeyShortcut.Modifier.command | KeyShortcut.Modifier.control)
        #expect(screenshot.problem(against: [screenshot]) == .takenBySystem)
        #expect(KeyShortcut(keyCode: 49, modifiers: KeyShortcut.Modifier.control).problem() == .takenBySystem)
    }

    @Test func modifiersOutsideTheFourAreDropped() {
        #expect(
            KeyShortcut(keyCode: 1, modifiers: KeyShortcut.Modifier.option | 1 << 1).modifiers
                == KeyShortcut.Modifier.option)
    }
}
