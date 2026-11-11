import Foundation

/// The columns the Processes table can show. The raw value is what is saved, so it must not change.
public enum TaskColumn: String, CaseIterable, Sendable, Codable {
    case name, cpu, memory, disk, network, gpu
    case pid, user, kind, threads, cpuTime, diskRead, diskWrite, received, sent, architecture

    /// The five shown by default, as in Windows' Processes tab.
    public var isShownByDefault: Bool {
        switch self {
        case .name, .cpu, .memory, .disk, .network, .gpu: true
        default: false
        }
    }

    /// Words read best A to Z, and numbers largest first, which is where a person looks for what is busy.
    public var sortsAscendingFirst: Bool {
        switch self {
        case .name, .user, .kind, .architecture, .pid: true
        default: false
        }
    }

    /// The name stays, or there would be nothing to tell the rows apart.
    public var canBeHidden: Bool { self != .name }
}

public struct TaskSort: Equatable, Sendable, Codable {
    public var column: TaskColumn
    public var ascending: Bool

    public init(column: TaskColumn, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }

    /// A to Z, so the list holds still until someone asks for the busiest first.
    public static let standard = TaskSort(column: .name, ascending: true)

    /// Busiest first, as Windows opens.
    public static let busiest = TaskSort(column: .cpu, ascending: false)

    /// As in Windows: by name the list is split into apps, background and system processes, and by anything else it is
    /// one list, so that the busiest come first whatever kind of process they are.
    public var groupsByKind: Bool { column == .name }
}

/// One line of the table.
public enum TaskRow: Hashable, Sendable {
    /// The title of Apps, Background Processes or System Processes, only while the list is sorted by name.
    case section(ProcessSection)
    /// A group's own line: an app with its helpers added in, or a process on its own.
    case group(ProcessKey)
    /// One process inside an open group.
    case member(group: ProcessKey, ProcessKey)
}

/// The table's lines in order, from the groups, the sort, the search and which groups are open.
public struct ProcessTable: Sendable {
    public private(set) var rows: [TaskRow] = []
    public private(set) var groups: [ProcessKey: ProcessGroup] = [:]
    /// Groups opened only because the search matched some of their processes and not the app itself.
    public private(set) var openedBySearch: Set<ProcessKey> = []
    private var members: [ProcessKey: [ProcessKey: ProcessUsage]] = [:]
    /// The groups in each section, which each section's title shows on every update.
    private var sectionCounts = [Int](repeating: 0, count: ProcessSection.allCases.count)

    public init() {}

    /// `names` holds where each name falls in Finder's order, so that sorting by name or user compares numbers rather
    /// than strings; it must have learnt every name and user name in `allGroups`, see `FinderOrder.learn`.
    public init(
        groups allGroups: [ProcessGroup], sort: TaskSort, query: String = "", expanded: Set<ProcessKey> = [],
        userNames: [UInt32: String] = [:], names: FinderOrder? = nil
    ) {
        let order = Ordering(sort: sort, userNames: userNames, names: names)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var visible: [(group: ProcessGroup, members: [ProcessUsage])] = []
        for group in allGroups {
            guard !words.isEmpty else {
                visible.append((group, group.members))
                continue
            }
            if Self.matches(group.total, name: group.name, words: words) {
                visible.append((group, group.members))
            } else {
                let found =
                    group.members.filter { Self.matches($0, name: $0.name, words: words) }
                    + (Self.matches(group.head, name: group.head.name, words: words) ? [group.head] : [])
                guard !found.isEmpty else { continue }
                openedBySearch.insert(group.id)
                visible.append((group, found))
            }
        }
        var rows: [TaskRow] = []
        var groups: [ProcessKey: ProcessGroup] = [:]
        var members: [ProcessKey: [ProcessKey: ProcessUsage]] = [:]
        groups.reserveCapacity(visible.count)
        rows.reserveCapacity(visible.count + ProcessSection.allCases.count)
        for line in visible { sectionCounts[line.group.section.rawValue] += 1 }
        let openedBySearch = openedBySearch
        /// The groups at `indices` in order, each followed by its processes when it is open.
        func append(_ indices: [Int]) {
            let sorted = order.sorted(indices, section: { visible[$0].group.section }, by: { visible[$0].group.total })
            for index in sorted {
                let (group, shownMembers) = visible[index]
                groups[group.id] = group
                rows.append(.group(group.id))
                // A group opened by the search shows its head among the matches, so the head is a member like the others.
                let isSearchResult = openedBySearch.contains(group.id)
                guard expanded.contains(group.id) || isSearchResult, !group.members.isEmpty || isSearchResult else {
                    continue
                }
                let listed = isSearchResult ? shownMembers : [group.head] + shownMembers
                var byKey: [ProcessKey: ProcessUsage] = [:]
                for index in order.sorted(Array(listed.indices), section: group.section, by: { listed[$0] }) {
                    let member = listed[index]
                    byKey[member.key] = member
                    rows.append(.member(group: group.id, member.key))
                }
                members[group.id] = byKey
            }
        }
        if sort.groupsByKind {
            for section in ProcessSection.allCases {
                let indices = visible.indices.filter { visible[$0].group.section == section }
                guard !indices.isEmpty else { continue }
                rows.append(.section(section))
                append(indices)
            }
        } else {
            append(Array(visible.indices))
        }
        self.rows = rows
        self.groups = groups
        self.members = members
    }

    public func group(_ key: ProcessKey) -> ProcessGroup? { groups[key] }

    /// What a line shows: a group's total, or one process.
    public func usage(of row: TaskRow) -> ProcessUsage? {
        switch row {
        case .section: nil
        case .group(let key): groups[key]?.total
        case .member(let group, let key): members[group]?[key]
        }
    }

    public func section(of row: TaskRow) -> ProcessSection? {
        switch row {
        case .section(let section): section
        case .group(let key), .member(let key, _): groups[key]?.section
        }
    }

    /// Where the section titles are. While this and the number of lines stay the same, every line can be refilled where
    /// it is, which costs far less than building the table's lines anew.
    public var sectionPositions: [Int] {
        rows.indices.filter { if case .section = rows[$0] { true } else { false } }
    }

    public func count(in section: ProcessSection) -> Int {
        sectionCounts[section.rawValue]
    }

    /// Every word must appear in the name, or be the process number.
    static func matches(_ usage: ProcessUsage, name: String, words: [String]) -> Bool {
        words.allSatisfy { word in
            name.localizedStandardContains(word) || String(usage.pid) == word
        }
    }
}

/// How two lines compare under a sort. Values nobody could read go last whichever way, so they never fill the top of the
/// table. A tie falls back to the name and then the process number, so equal lines do not swap places on every update.
struct Ordering {
    let sort: TaskSort
    let userNames: [UInt32: String]
    var names: FinderOrder? = nil

    /// What one line is sorted by, worked out once for the line rather than on each of the thousands of comparisons a
    /// sort makes: a number, where names stand for their place in Finder's order.
    private struct SortKey {
        let index: Int
        let value: Double?
        let sortName: String
        let key: ProcessKey
    }

    /// The order of `indices` under this sort, all lines being in `section`.
    func sorted(_ indices: [Int], section: ProcessSection, by usage: (Int) -> ProcessUsage) -> [Int] {
        sorted(indices, section: { _ in section }, by: usage)
    }

    /// The order of `indices` under this sort, each line in its own section. Same order as `precedes`, which a sort by
    /// name or user falls back to when no learnt order of names is at hand.
    func sorted(_ indices: [Int], section: (Int) -> ProcessSection, by usage: (Int) -> ProcessUsage) -> [Int] {
        var keys: [SortKey] = []
        keys.reserveCapacity(indices.count)
        for index in indices {
            let line = usage(index)
            guard let value = value(of: line, section(index)) else {
                return indices.sorted { precedes(usage($0), section($0), usage($1), section($1)) }
            }
            keys.append(SortKey(index: index, value: value, sortName: line.sortName, key: line.key))
        }
        keys.sort { left, right in
            let ascending: Bool? =
                switch (left.value, right.value) {
                case (nil, nil): nil
                case (nil, _): !sort.ascending
                case (_, nil): sort.ascending
                case (let left?, let right?): left == right ? nil : left < right
                }
            if let ascending { return ascending == sort.ascending }
            return left.sortName != right.sortName ? left.sortName < right.sortName : left.key < right.key
        }
        return keys.map(\.index)
    }

    /// The figure a line is sorted by, nil inside when the figure is unknown, or nil outside when the line can only be
    /// placed by comparing strings.
    private func value(of line: ProcessUsage, _ section: ProcessSection) -> Double?? {
        func rank(_ word: String) -> Double?? {
            guard let rank = names?.rank(of: word) else { return nil }
            return .some(Double(rank))
        }
        return switch sort.column {
        case .name: rank(line.name)
        case .user: rank(userNames[line.userID] ?? String(line.userID))
        case .cpu: .some(line.cpu)
        case .memory: .some(line.memory.map(Double.init))
        case .disk: .some(line.diskRate)
        case .network: .some(line.networkRate)
        case .gpu: .some(line.gpu)
        case .pid: .some(Double(line.pid))
        case .kind: .some(Double(section.rawValue))
        case .threads: .some(line.threads.map(Double.init))
        case .cpuTime: .some(line.cpuTime)
        case .diskRead: .some(line.diskReadRate)
        case .diskWrite: .some(line.diskWriteRate)
        case .received: .some(line.receiveRate)
        case .sent: .some(line.sendRate)
        case .architecture: .some(line.isTranslated.map { $0 ? 1 : 0 })
        }
    }

    func precedes(
        _ left: ProcessUsage, _ leftSection: ProcessSection, _ right: ProcessUsage, _ rightSection: ProcessSection
    )
        -> Bool
    {
        switch compare(left, leftSection, right, rightSection) {
        case .some(let ascending): return ascending == sort.ascending
        case .none:
            return left.sortName != right.sortName ? left.sortName < right.sortName : left.key < right.key
        }
    }

    /// True when the left comes first in ascending order, false when the right does, nil for a tie. A missing value
    /// answers so that it ends up last.
    private func compare(
        _ left: ProcessUsage, _ leftSection: ProcessSection, _ right: ProcessUsage, _ rightSection: ProcessSection
    )
        -> Bool?
    {
        func numbers<Value: Comparable>(_ value: (ProcessUsage) -> Value?) -> Bool? {
            switch (value(left), value(right)) {
            case (nil, nil): return nil
            case (nil, _): return !sort.ascending
            case (_, nil): return sort.ascending
            case (let left?, let right?): return left == right ? nil : left < right
            }
        }
        func words(_ left: String, _ right: String) -> Bool? {
            if let names, let leftRank = names.rank(of: left), let rightRank = names.rank(of: right) {
                return leftRank == rightRank ? nil : leftRank < rightRank
            }
            let order = left.localizedStandardCompare(right)
            return order == .orderedSame ? nil : order == .orderedAscending
        }
        switch sort.column {
        case .name: return words(left.name, right.name)
        case .cpu: return numbers(\.cpu)
        case .memory: return numbers(\.memory)
        case .disk: return numbers(\.diskRate)
        case .network: return numbers(\.networkRate)
        case .gpu: return numbers(\.gpu)
        case .pid: return left.pid == right.pid ? nil : left.pid < right.pid
        case .user:
            return words(userNames[left.userID] ?? String(left.userID), userNames[right.userID] ?? String(right.userID))
        case .kind: return leftSection == rightSection ? nil : leftSection < rightSection
        case .threads: return numbers(\.threads)
        case .cpuTime: return numbers(\.cpuTime)
        case .diskRead: return numbers(\.diskReadRate)
        case .diskWrite: return numbers(\.diskWriteRate)
        case .received: return numbers(\.receiveRate)
        case .sent: return numbers(\.sendRate)
        case .architecture: return numbers { $0.isTranslated.map { $0 ? 1 : 0 } }
        }
    }
}

/// Where each name falls in Finder's order, worked out once for each name.
///
/// Comparing two names the way Finder does takes microseconds, and putting 500 lines in order by name compared thousands of
/// pairs on every update: 9 ms of the main thread each second, enough to drop a frame while the list scrolled. Names
/// hardly change between updates, so each new one finds its place once, and a sort compares two numbers.
public struct FinderOrder: Sendable {
    /// Every name learnt, in Finder's order.
    private var sorted: [String] = []
    /// Whether each name in `sorted` is equal in Finder's order to the one before it, such as two that differ only in case.
    private var tied: [Bool] = []
    /// The place of each name, shared by names that are equal.
    private var ranks: [String: Int] = [:]

    /// Past this many new names at once, sorting them all is quicker than finding a place for each.
    private static let largestInsertion = 32

    public init() {}

    public func rank(of name: String) -> Int? { ranks[name] }

    /// Learns the names in use and those of the users, which are what sorting by name and by user compares. Names no
    /// longer in use are let go once they outnumber the rest.
    public mutating func learn(_ groups: [ProcessGroup], userNames: [UInt32: String]) {
        var inUse = Set<String>(minimumCapacity: groups.count * 2)
        for group in groups {
            inUse.insert(group.total.name)
            inUse.insert(group.head.name)
            for member in group.members { inUse.insert(member.name) }
        }
        inUse.formUnion(userNames.values)
        learn(inUse)
    }

    mutating func learn(_ inUse: Set<String>) {
        let fresh = inUse.filter { ranks[$0] == nil }
        if sorted.count > inUse.count * 2 + Self.largestInsertion {
            rebuild(from: Array(inUse))
        } else if fresh.count > Self.largestInsertion {
            rebuild(from: sorted + fresh)
        } else if !fresh.isEmpty {
            for name in fresh { insert(name) }
            numberRanks()
        }
    }

    private mutating func rebuild(from names: [String]) {
        sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        tied = sorted.indices.map { $0 > 0 && sorted[$0 - 1].localizedStandardCompare(sorted[$0]) == .orderedSame }
        numberRanks()
    }

    /// Binary search keeps everything before `low` ahead of the name and everything from `high` after it, so a search
    /// that meets no equal name ends where none exists.
    private mutating func insert(_ name: String) {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            switch name.localizedStandardCompare(sorted[middle]) {
            case .orderedSame:
                sorted.insert(name, at: middle + 1)
                tied.insert(true, at: middle + 1)
                return
            case .orderedAscending: high = middle
            case .orderedDescending: low = middle + 1
            }
        }
        sorted.insert(name, at: low)
        tied.insert(false, at: low)
    }

    private mutating func numberRanks() {
        ranks.removeAll(keepingCapacity: true)
        var rank = 0
        for (index, name) in sorted.enumerated() {
            if index > 0, !tied[index] { rank += 1 }
            ranks[name] = rank
        }
    }
}
