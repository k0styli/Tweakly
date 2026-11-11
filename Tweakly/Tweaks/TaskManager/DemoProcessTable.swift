#if TWEAKLY_AUTOMATION
    import Darwin
    import Foundation
    import TaskManagerCore

    /// Test copies with the `demoData` preference only, for pictures that will be published: a made-up Mac whose
    /// processes are the apps and services every Mac has, instead of this Mac's own. The rows go through the same tracker
    /// and grouping as real ones, so the sections, groups and rates behave as they would.
    nonisolated struct DemoProcessTable {
        private struct Row {
            let pid: Int32
            let name: String
            let path: String?
            /// The app a helper works for, which groups it under that app.
            let owner: Int32?
            let isRoot: Bool
            /// Cores, as in Activity Monitor.
            let cpu: Double
            let megabytes: Double
            let read: Double
            let write: Double
            let gpu: Double
            let down: Double
            let up: Double
        }

        /// An app of the made-up Mac: its process, whether it has a Dock icon, and its bundle for the icon.
        private struct App {
            let pid: Int32
            let bundle: String
            let isRegular: Bool
        }

        private let rows: [Row]
        private let apps: [App]
        private var cpuTime: [Int32: Double] = [:]
        private var gpuTime: [Int32: Double] = [:]
        private var bytesRead: [Int32: Double] = [:]
        private var bytesWritten: [Int32: Double] = [:]
        private var last: Double?
        private let user = getuid()

        init() {
            // Process numbers that no running app has now, so that no real app lends a row its icon.
            var base: Int32 = 61_000
            while (0..<40).contains(where: { kill(base + $0, 0) == 0 || errno == EPERM }) { base += 1_000 }
            func pid(_ offset: Int32) -> Int32 { base + offset }

            let safari = pid(1)
            let mail = pid(2)
            let music = pid(3)
            let photos = pid(4)
            let notes = pid(5)
            let finder = pid(6)
            let preview = pid(7)
            let messages = pid(8)
            let tweakly = pid(9)
            let webkit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
            let core = "/System/Library/CoreServices/"
            let appList = [
                App(pid: safari, bundle: "/Applications/Safari.app", isRegular: true),
                App(pid: mail, bundle: "/System/Applications/Mail.app", isRegular: true),
                App(pid: music, bundle: "/System/Applications/Music.app", isRegular: true),
                App(pid: photos, bundle: "/System/Applications/Photos.app", isRegular: true),
                App(pid: notes, bundle: "/System/Applications/Notes.app", isRegular: true),
                App(pid: finder, bundle: core + "Finder.app", isRegular: true),
                App(pid: preview, bundle: "/System/Applications/Preview.app", isRegular: true),
                App(pid: messages, bundle: "/System/Applications/Messages.app", isRegular: true),
                App(pid: tweakly, bundle: "/Applications/Tweakly.app", isRegular: false),
            ]
            func app(_ pid: Int32, _ executable: String) -> String {
                (appList.first { $0.pid == pid }?.bundle ?? "") + "/Contents/MacOS/" + executable
            }
            func helper(_ offset: Int32, _ name: String, _ xpc: String, for owner: Int32) -> (
                Int32, String, String, Int32
            ) {
                (pid(offset), name, webkit + xpc + ".xpc/Contents/MacOS/" + xpc, owner)
            }
            let content = "com.apple.WebKit.WebContent"
            let networking = "com.apple.WebKit.Networking"
            let media = "com.apple.WebKit.GPU"
            var rows: [Row] = []
            func add(
                _ pid: Int32, _ name: String, _ path: String?, owner: Int32? = nil, root: Bool = false, cpu: Double,
                mb: Double, read: Double = 0, write: Double = 0, gpu: Double = 0, down: Double = 0, up: Double = 0
            ) {
                rows.append(
                    Row(
                        pid: pid, name: name, path: path, owner: owner, isRoot: root, cpu: cpu, megabytes: mb,
                        read: read,
                        write: write, gpu: gpu, down: down, up: up))
            }
            // Apps.
            add(safari, "Safari", app(safari, "Safari"), cpu: 0.06, mb: 214, write: 24_000, down: 6_000, up: 1_500)
            for (index, (offset, name, xpc)) in [
                (Int32(10), "Safari Web Content", content), (11, "Safari Web Content", content),
                (12, "Safari Web Content", content), (13, "Safari Networking", networking),
                (14, "Safari Graphics and Media", media),
            ].enumerated() {
                let row = helper(offset, name, xpc, for: safari)
                let weights: [(Double, Double, Double, Double)] = [
                    (0.21, 412, 0, 0), (0.07, 268, 0, 0), (0.02, 131, 0, 0), (0.03, 38, 0, 0), (0.05, 96, 0.031, 0),
                ]
                let weight = weights[index]
                add(
                    row.0, row.1, row.2, owner: row.3, cpu: weight.0, mb: weight.1, gpu: weight.2,
                    down: xpc == networking ? 486_000 : 0, up: xpc == networking ? 38_000 : 0)
            }
            add(mail, "Mail", app(mail, "Mail"), cpu: 0.012, mb: 296, read: 6_000, write: 41_000, down: 14_000)
            add(pid(15), "com.apple.MailServiceAgent", nil, owner: mail, cpu: 0.002, mb: 18)
            add(music, "Music", app(music, "Music"), cpu: 0.041, mb: 247, read: 180_000, gpu: 0.004, down: 162_000)
            add(
                photos, "Photos", app(photos, "Photos"), cpu: 0.094, mb: 538, read: 1_240_000, write: 310_000,
                gpu: 0.018)
            add(
                pid(16), "photoanalysisd", "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/photoanalysisd",
                owner: photos, cpu: 0.152, mb: 186, read: 620_000, gpu: 0.012)
            add(notes, "Notes", app(notes, "Notes"), cpu: 0.004, mb: 154)
            add(finder, "Finder", app(finder, "Finder"), cpu: 0.008, mb: 118, read: 12_000)
            add(preview, "Preview", app(preview, "Preview"), cpu: 0.001, mb: 86)
            add(messages, "Messages", app(messages, "Messages"), cpu: 0.006, mb: 172, down: 2_000, up: 900)
            add(tweakly, "Tweakly", app(tweakly, "Tweakly"), cpu: 0.002, mb: 13)
            // The system's own, a few of root's among them.
            let system: [(String, String?, Bool, Double, Double, Double, Double)] = [
                ("kernel_task", nil, true, 0.31, 1_840, 0, 0),
                (
                    "WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
                    false,
                    0.142, 412, 0.064, 0
                ),
                ("launchd", "/sbin/launchd", true, 0.011, 34, 0, 0),
                (
                    "mds_stores",
                    "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Versions/A/Support/mds_stores",
                    true, 0.046, 96, 0, 820_000
                ),
                ("coreaudiod", "/usr/sbin/coreaudiod", true, 0.019, 28, 0, 0),
                ("Dock", core + "Dock.app/Contents/MacOS/Dock", false, 0.004, 92, 0.002, 0),
                ("ControlCenter", core + "ControlCenter.app/Contents/MacOS/ControlCenter", false, 0.006, 74, 0, 0),
                ("Spotlight", core + "Spotlight.app/Contents/MacOS/Spotlight", false, 0.002, 61, 0, 0),
                ("loginwindow", core + "loginwindow.app/Contents/MacOS/loginwindow", false, 0.001, 52, 0, 0),
                (
                    "cloudd", "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd", false, 0.009,
                    41, 0, 0
                ),
                ("bluetoothd", "/usr/sbin/bluetoothd", true, 0.007, 22, 0, 0),
                ("airportd", "/usr/libexec/airportd", true, 0.003, 16, 0, 0),
                ("logd", "/usr/libexec/logd", true, 0.012, 24, 0, 46_000),
                ("trustd", "/usr/libexec/trustd", false, 0.001, 11, 0, 0),
                ("distnoted", "/usr/sbin/distnoted", false, 0.001, 6, 0, 0),
                ("mDNSResponder", "/usr/sbin/mDNSResponder", true, 0.002, 9, 0, 0),
                ("powerd", "/System/Library/CoreServices/powerd.bundle/powerd", true, 0.001, 7, 0, 0),
                ("opendirectoryd", "/usr/libexec/opendirectoryd", true, 0.001, 18, 0, 0),
                ("UserEventAgent", "/usr/libexec/UserEventAgent", false, 0.001, 14, 0, 0),
                ("sharingd", "/usr/libexec/sharingd", false, 0.002, 21, 0, 0),
                (
                    "NotificationCenter",
                    "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter", false,
                    0.001,
                    48, 0, 0
                ),
                ("corebrightnessd", "/usr/libexec/corebrightnessd", true, 0.001, 8, 0, 0),
            ]
            for (index, entry) in system.enumerated() {
                add(
                    pid(20 + Int32(index)), entry.0, entry.1, root: entry.2, cpu: entry.3, mb: entry.4, write: entry.6,
                    gpu: entry.5, down: entry.0 == "cloudd" ? 31_000 : 0, up: entry.0 == "cloudd" ? 12_000 : 0)
            }
            self.rows = rows
            apps = appList
        }

        struct Reading {
            var counters: [ProcessCounters]
            var apps: [Int32: AppIdentity]
            var responsible: [Int32: Int32]
            var userNames: [UInt32: String]
        }

        /// Each figure drifts around its value, slowly and differently for each process, as a real Mac's do.
        private static func drift(_ pid: Int32, _ now: Double) -> Double {
            1 + 0.22 * sin(now / 3.1 + Double(pid % 97)) + 0.08 * sin(now / 0.9 + Double(pid % 13))
        }

        mutating func read(at now: Double) -> Reading {
            let elapsed = last.map { max(0, now - $0) } ?? 0
            last = now
            var counters: [ProcessCounters] = []
            counters.reserveCapacity(rows.count)
            var responsible: [Int32: Int32] = [:]
            for row in rows {
                let drift = Self.drift(row.pid, now)
                cpuTime[row.pid, default: 40 + row.cpu * 9_000] += row.cpu * drift * elapsed
                gpuTime[row.pid, default: row.gpu * 2_000] += row.gpu * drift * elapsed
                bytesRead[row.pid, default: 0] += row.read * drift * elapsed
                bytesWritten[row.pid, default: 0] += row.write * drift * elapsed
                if let owner = row.owner { responsible[row.pid] = owner }
                counters.append(
                    ProcessCounters(
                        key: ProcessKey(pid: row.pid, start: 1), parentPID: 1, userID: row.isRoot ? 0 : user,
                        name: row.name, path: row.path, cpuTime: UInt64((cpuTime[row.pid] ?? 0) * 1e9),
                        memory: UInt64(row.megabytes * (1 + 0.01 * sin(now / 7 + Double(row.pid % 5))) * 1_048_576),
                        diskRead: UInt64(bytesRead[row.pid] ?? 0), diskWritten: UInt64(bytesWritten[row.pid] ?? 0),
                        threads: 4 + Int(row.megabytes / 20), gpuTime: UInt64((gpuTime[row.pid] ?? 0) * 1e9),
                        receiveRate: row.down * drift, sendRate: row.up * drift, isTranslated: false))
            }
            var identities: [Int32: AppIdentity] = [:]
            for app in apps {
                let shown = FileManager.default.displayName(atPath: app.bundle)
                identities[app.pid] = AppIdentity(
                    pid: app.pid, name: shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown,
                    bundlePath: app.bundle, isRegular: app.isRegular)
            }
            return Reading(
                counters: counters, apps: identities, responsible: responsible, userNames: [0: "root", user: "user"])
        }
    }
#endif
