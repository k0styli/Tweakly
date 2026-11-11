import Foundation
import Testing

@testable import UninstallerCore

/// Apps as they really are on a Mac, as far as matching their files goes.
private enum Apps {
    static let chrome = AppIdentity(
        path: "/Applications/Google Chrome.app", bundleID: "com.google.Chrome",
        names: ["Google Chrome", "Chrome", "Google Chrome"], teamID: "EQHXZ8M8AV")
    static let capCut = AppIdentity(
        path: "/Applications/CapCut.app", bundleID: "com.lemon.lvoverseas", names: ["CapCut"], teamID: "22MMUN2RN5",
        groups: ["22MMUN2RN5.lv", "22MMUN2RN5.ve"], embeddedIDs: ["com.lemon.lvoverseas.share"])
    static let docker = AppIdentity(
        path: "/Applications/Docker.app", bundleID: "com.docker.docker", names: ["Docker", "com.docker.backend"],
        teamID: "9BNSXJN65R", groups: ["group.com.docker"],
        embeddedIDs: ["com.docker.vmnetd", "com.electron.dockerdesktop", "org.sparkle-project.Sparkle.Autoupdate"])
    static let telegram = AppIdentity(
        path: "/Applications/Telegram.app", bundleID: "com.tdesktop.Telegram", names: ["Telegram"])
    static let vsCode = AppIdentity(
        path: "/Applications/Visual Studio Code.app", bundleID: "com.microsoft.VSCode",
        names: ["Visual Studio Code", "Code"])
    static let figma = AppIdentity(
        path: "/Applications/Figma.app", bundleID: "com.figma.Desktop", names: ["Figma"],
        embeddedIDs: ["com.figma.agent"])
    static let xcode = AppIdentity(
        path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode", names: ["Xcode"],
        embeddedIDs: ["com.apple.iphonesimulator", "com.apple.dt.Instruments"])
    static let clash = AppIdentity(
        path: "/Applications/Clash Verge.app", bundleID: "io.github.clash-verge-rev.clash-verge-rev",
        names: ["Clash Verge", "clash-verge"])
    static let kurdy = AppIdentity(
        path: "/Applications/Kurdy Uploader.app", bundleID: "com.kurdy.uploader", names: ["Kurdy Uploader"])
    static let kurdyCopy = AppIdentity(
        path: "/Applications/Kurdy Uploader (version 1.7.86).app", bundleID: "com.kurdy.uploader",
        names: ["Kurdy Uploader (version 1.7.86)", "Kurdy Uploader"])
    static let word = AppIdentity(
        path: "/Applications/Microsoft Word.app", bundleID: "com.microsoft.Word", names: ["Microsoft Word"],
        teamID: "UBF8T346G9", groups: ["UBF8T346G9.Office", "UBF8T346G9.ms"])
    static let excel = AppIdentity(
        path: "/Applications/Microsoft Excel.app", bundleID: "com.microsoft.Excel", names: ["Microsoft Excel"],
        teamID: "UBF8T346G9", groups: ["UBF8T346G9.Office"])
}

@Suite struct LeftoverMatcherTests {
    private let all = [
        Apps.chrome, Apps.capCut, Apps.docker, Apps.telegram, Apps.vsCode, Apps.figma, Apps.xcode, Apps.clash,
        Apps.word, Apps.excel,
    ]

    private func owner(_ entry: String, _ place: LeftoverPlace, in apps: [AppIdentity]? = nil) -> String? {
        let apps = apps ?? all
        return LeftoverMatcher(apps: apps, foreignNames: ["music", "notes"]).owner(of: entry, in: place).map {
            apps[$0].bundleID
        }
    }

    @Test func anIdNamesItsApp() {
        #expect(owner("com.google.Chrome.plist", .preferences) == "com.google.Chrome")
        #expect(owner("com.lemon.lvoverseas", .containers) == "com.lemon.lvoverseas")
        #expect(owner("com.google.Chrome.savedState", .savedState) == "com.google.Chrome")
    }

    @Test func folderNamesAreComparedWithoutCase() {
        #expect(owner("COM.GOOGLE.CHROME", .caches) == "com.google.Chrome")
    }

    @Test func whatHangsBelowAnIdIsTheAppsToo() {
        #expect(owner("com.figma.Desktop.ShipIt", .caches) == "com.figma.Desktop")
        #expect(
            owner("com.figma.Desktop.ShipIt.5BCFD06D-77C7-52CE-A93D-A659A96E348F.plist", .preferencesByHost)
                == "com.figma.Desktop")
        #expect(owner("com.lemon.lvoverseas.share", .containers) == "com.lemon.lvoverseas")
    }

    @Test func anotherEditionIsNotTheApp() {
        #expect(owner("com.google.Chrome.canary", .caches) == nil)
        #expect(owner("com.google.Chrome.beta.plist", .preferences) == nil)
    }

    @Test func anAppThatStaysKeepsItsFiles() {
        let matcher = LeftoverMatcher(apps: [Apps.chrome], foreignIDs: ["com.google.Chrome.Canary"])
        #expect(matcher.owner(of: "com.google.Chrome.canary", in: .caches) == nil)
        #expect(matcher.owner(of: "com.google.Chrome", in: .caches) == 0)
    }

    @Test func aSecondCopyKeepsTheData() {
        let apps = [Apps.kurdy, Apps.kurdyCopy]
        #expect(owner("com.kurdy.uploader", .applicationSupport, in: apps) == nil)
        #expect(owner("Kurdy Uploader", .logs, in: apps) == nil)
        #expect(owner("com.kurdy.uploader", .applicationSupport, in: [Apps.kurdy]) == "com.kurdy.uploader")
    }

    @Test func aGroupSharedByTwoAppsStays() {
        #expect(owner("UBF8T346G9.Office", .groupContainers) == nil)
        #expect(owner("UBF8T346G9.ms", .groupContainers) == "com.microsoft.Word")
        #expect(owner("UBF8T346G9.Office", .groupContainers, in: [Apps.word]) == "com.microsoft.Word")
        #expect(owner("22MMUN2RN5.lv", .applicationScripts) == "com.lemon.lvoverseas")
    }

    @Test func groupsCountOnlyWhereGroupsLive() {
        #expect(owner("group.com.docker", .groupContainers) == "com.docker.docker")
        #expect(owner("group.com.docker", .caches) == nil)
    }

    @Test func helpersFromTheSameCompanyAreTheApps() {
        #expect(owner("com.docker.vmnetd", .privilegedHelperTools) == "com.docker.docker")
        #expect(owner("com.electron.dockerdesktop.plist", .preferences) == nil)
        #expect(owner("org.sparkle-project.Sparkle", .caches) == nil)
        #expect(owner("com.figma.agent", .httpStorages) == "com.figma.Desktop")
    }

    @Test func namesCountOnlyWhereAppsUseThem() {
        #expect(owner("Code", .applicationSupport) == "com.microsoft.VSCode")
        #expect(owner("Telegram Desktop", .applicationSupport) == "com.tdesktop.Telegram")
        #expect(owner("Docker Desktop", .applicationSupport) == "com.docker.docker")
        #expect(owner("Clash Verge", .logs) == "io.github.clash-verge-rev.clash-verge-rev")
        #expect(owner("Telegram.plist", .preferences) == nil)
    }

    @Test func commonWordsAndMacOSNamesAreNobodys() {
        let notes = AppIdentity(path: "/Applications/Notes Pro.app", bundleID: "com.example.notes", names: ["Notes"])
        #expect(owner("Notes", .applicationSupport, in: [notes]) == nil)
        let music = AppIdentity(path: "/Applications/M.app", bundleID: "com.example.m", names: ["Music"])
        #expect(owner("Music", .applicationSupport, in: [music]) == nil)
    }

    @Test func appleFilesAreOnlyApplesOwnApps() {
        #expect(owner("com.apple.dt.Xcode", .caches) == "com.apple.dt.Xcode")
        #expect(owner("com.apple.dt.Xcode.sourcecontrol.Git", .caches) == "com.apple.dt.Xcode")
        // What Xcode carries is shared with macOS and other tools.
        #expect(owner("com.apple.iphonesimulator.plist", .preferences) == nil)
        #expect(owner("Xcode", .applicationSupport) == nil)
        let sneaky = AppIdentity(
            path: "/Applications/S.app", bundleID: "com.example.s", names: ["S"], embeddedIDs: ["com.apple.Safari"])
        #expect(owner("com.apple.Safari", .containers, in: [sneaky]) == nil)
    }

    @Test func aCompanyFolderHoldsItsAppsFolder() {
        let matcher = LeftoverMatcher(apps: all)
        #expect(matcher.isVendorFolder("Google"))
        #expect(
            matcher.owner(ofVendorChild: "Chrome", vendorFolder: "Google").map { all[$0].bundleID }
                == "com.google.Chrome")
        #expect(matcher.owner(ofVendorChild: "GoogleUpdater", vendorFolder: "Google") == nil)
        #expect(matcher.owner(ofVendorChild: "Chrome", vendorFolder: "Microsoft") == nil)
        #expect(!matcher.isVendorFolder("github"))
    }

    @Test func aJobBelongsToTheAppItRunsFrom() {
        let matcher = LeftoverMatcher(apps: all)
        let agent = LaunchJob(
            label: "io.github.clash-verge-rev.clash-verge-rev",
            program: "/Applications/Clash Verge.app/Contents/MacOS/clash-verge")
        #expect(
            matcher.owner(ofJob: agent, fileName: "x.plist", in: .launchAgents).map { all[$0].bundleID }
                == Apps.clash.bundleID)
        let socket = LaunchJob(
            label: "com.docker.socket", program: "/Library/PrivilegedHelperTools/com.docker.socket",
            associatedBundleIDs: ["com.docker.docker"])
        #expect(
            matcher.owner(ofJob: socket, fileName: "com.docker.socket.plist", in: .systemLaunchDaemons).map {
                all[$0].bundleID
            } == "com.docker.docker")
        let vmnetd = LaunchJob(label: "com.docker.vmnetd", program: "/Library/PrivilegedHelperTools/com.docker.vmnetd")
        #expect(
            matcher.owner(ofJob: vmnetd, fileName: "com.docker.vmnetd.plist", in: .systemLaunchDaemons).map {
                all[$0].bundleID
            } == "com.docker.docker")
        let someoneElses = LaunchJob(label: "com.docker.helper", associatedBundleIDs: ["com.example.other"])
        #expect(matcher.owner(ofJob: someoneElses, fileName: "com.docker.helper.plist", in: .launchAgents) == nil)
    }
}

@Suite struct NameTests {
    @Test func versionsAreLeftOut() {
        #expect(NameKey.withoutVersion("Bartender 6") == "Bartender")
        #expect(NameKey.withoutVersion("Kurdy Uploader (version 1.7.86)") == "Kurdy Uploader")
        #expect(NameKey.withoutVersion("Mac2") == "Mac2")
        #expect(NameKey.withoutVersion("1Password 8") == "1Password")
    }

    @Test func keysIgnoreCaseSpacesAndPunctuation() {
        #expect(NameKey.key("Kurdy Uploader") == NameKey.key("KurdyUploader"))
        #expect(NameKey.key("Clash-Verge") == "clashverge")
        #expect(NameKey.key("Café") == "cafe")
    }

    @Test func theKindFollowsTheProcessors() {
        #expect(AppKind(architectures: ["arm64"]) == .appleSilicon)
        #expect(AppKind(architectures: ["arm64", "x86_64"]) == .universal)
        #expect(AppKind(architectures: ["x86_64"]) == .intel)
        #expect(AppKind(architectures: []) == .unknown)
    }

    @Test func byHostPreferencesLoseTheirHost() {
        #expect(
            LeftoverPlace.preferencesByHost.stem(of: "com.example.app.5BCFD06D-77C7-52CE-A93D-A659A96E348F.plist")
                == "com.example.app")
        #expect(LeftoverPlace.preferencesByHost.stem(of: "com.example.app.001122aabbcc.plist") == "com.example.app")
        #expect(LeftoverPlace.preferences.stem(of: "com.example.app.helper.plist") == "com.example.app.helper")
    }
}

@Suite struct AdministratorScriptTests {
    private let home = "/Users/someone"

    @Test func quotesSurviveTheShell() {
        #expect(AdministratorScript.quoted("it's") == "'it'\\''s'")
        #expect(AdministratorScript.quoted("$(rm -rf /)") == "'$(rm -rf /)'")
    }

    @Test func onlyPlacesAppsInstallIntoCanBeTouched() {
        let ok = [
            "/Applications/Xcode.app", "/Applications/Python 3.11/IDLE.app", "/Users/someone/Applications/A.app",
            "/Users/someone/Library/Caches/com.example", "/Library/LaunchDaemons/com.docker.vmnetd.plist",
            "/Library/PrivilegedHelperTools/com.docker.vmnetd", "/Library/Application Support/Vendor",
        ]
        for path in ok { #expect(AdministratorScript.isRemovable(path, home: home), "\(path)") }
        let refused = [
            "/Applications", "/Applications/Utilities", "/System/Applications/Music.app", "/Users/someone/Library",
            "/Users/someone/Library/Caches", "/Users/someone/Documents/x", "/Library/LaunchDaemons",
            "/Applications/../System/x.app", "/Users/someone/Library/Caches/a\nb", "relative/x.app",
            "/Library/Application Support/", "/usr/bin/x", "/Users/someone/Library//Caches",
        ]
        for path in refused { #expect(!AdministratorScript.isRemovable(path, home: home), "\(path)") }
    }

    @Test func theScriptStopsJobsThenMovesStraightToTheTrash() {
        let script = AdministratorScript.removal(
            moving: ["/Applications/Xcode.app", "/Library/LaunchDaemons/a'b.plist"], toTrash: "/Users/x/.Trash",
            stopping: [StoppedJob(domain: .system, plist: "/Library/LaunchDaemons/a'b.plist")], owner: 501, group: 20)
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines[0] == "/bin/launchctl 'bootout' 'system' '/Library/LaunchDaemons/a'\\''b.plist' 2>/dev/null")
        #expect(lines[1].hasPrefix("if [ -e '/Applications/Xcode.app' ] || [ -L '/Applications/Xcode.app' ]; then"))
        #expect(lines[1].contains("for t in '/Users/x/.Trash/Xcode.app' '/Users/x/.Trash/Xcode 2.app' "))
        #expect(lines[1].contains("/bin/mv -n '/Applications/Xcode.app' \"$t\""))
        #expect(lines[1].contains("-type f -links 1"))
        #expect(lines[1].contains("-exec /usr/sbin/chown -h 501:20 {} +"))
        #expect(!lines[1].contains("chown -R"))
        #expect(lines[1].contains("echo \"0\t$t\""))
        #expect(lines[2].contains("'/Users/x/.Trash/a'\\''b 2.plist'"))
        #expect(lines.last == "exit 0")
    }

    @Test func theAppGoesFirstAndAloneIfItCannotGo() {
        let script = AdministratorScript.removal(
            moving: ["/Applications/A.app", "/Library/LaunchDaemons/a.plist"], toTrash: "/Users/x/.Trash",
            stopping: [StoppedJob(domain: .system, plist: "/Library/LaunchDaemons/a.plist")], owner: 501, group: 20,
            firstMustMove: true, keepingOwner: [0])
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("if [ -e '/Applications/A.app' ]"))
        #expect(!lines[0].contains("chown"))
        #expect(lines[1] == "if [ -e '/Applications/A.app' ] || [ -L '/Applications/A.app' ]; then exit 0; fi")
        #expect(lines[2].hasPrefix("/bin/launchctl 'bootout'"))
        #expect(lines[3].contains("chown"))
        #expect(lines[3].contains("echo \"1\t$t\""))
    }

    @Test func nothingElseMovesWhenTheAppStays() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "uninstaller-first-\(UUID().uuidString)").path
        defer { try? manager.removeItem(atPath: root) }
        let trash = root + "/Trash"
        try manager.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try manager.createDirectory(atPath: root + "/Locked/A.app", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/data.plist"))
        // A folder nobody can write to holds the app in place, as a sealed volume or App Management would.
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root + "/Locked")
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/Locked") }
        let script = AdministratorScript.removal(
            moving: [root + "/Locked/A.app", root + "/data.plist"], toTrash: trash, stopping: [], owner: getuid(),
            group: getgid(), firstMustMove: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(AdministratorScript.movedItems(in: output).isEmpty)
        #expect(manager.fileExists(atPath: root + "/Locked/A.app"))
        #expect(manager.fileExists(atPath: root + "/data.plist"))
    }

    @Test func trashNamesCountUpAsFindersDo() {
        #expect(
            AdministratorScript.trashNames(for: "Xcode.app", count: 3) == ["Xcode.app", "Xcode 2.app", "Xcode 3.app"])
        #expect(
            AdministratorScript.trashNames(for: "com.docker.vmnetd", count: 2) == [
                "com.docker.vmnetd", "com.docker 2.vmnetd",
            ])
        #expect(AdministratorScript.trashNames(for: "Logs", count: 2) == ["Logs", "Logs 2"])
    }

    @Test func theScriptMovesNextToWhatTheTrashHoldsNotIntoIt() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "uninstaller-script-\(UUID().uuidString)").path
        defer { try? manager.removeItem(atPath: root) }
        let trash = root + "/Trash"
        try manager.createDirectory(atPath: root + "/Apps/A.app/Contents", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: trash + "/A.app", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/Apps/it's.plist"))
        let script = AdministratorScript.removal(
            moving: [root + "/Apps/A.app", root + "/Apps/it's.plist", root + "/Apps/missing"], toTrash: trash,
            stopping: [], owner: getuid(), group: getgid())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let moved = AdministratorScript.movedItems(in: output)
        #expect(moved == [0: trash + "/A 2.app", 1: trash + "/it's.plist"])
        #expect(manager.fileExists(atPath: trash + "/A 2.app/Contents"))
        #expect(!manager.fileExists(atPath: trash + "/A.app/A.app"))
        #expect(!manager.fileExists(atPath: root + "/Apps/A.app"))
        #expect(process.terminationStatus == 0)
    }

    @Test func theScriptsOutputSaysWhereEachItemWent() {
        let moved = AdministratorScript.movedItems(
            in: "0\t/Users/x/.Trash/Xcode.app\r2\t/Users/x/.Trash/a b 2.plist\rnoise")
        #expect(moved == [0: "/Users/x/.Trash/Xcode.app", 2: "/Users/x/.Trash/a b 2.plist"])
    }
}

@Suite struct LeftoverTests {
    @Test func theSheetListsTheAppThenTheBiggestDataFirst() {
        let items = [
            Leftover(path: "/u/Library/Caches/a", place: .caches, size: 5),
            Leftover(path: "/u/Library/Containers/a", place: .containers, size: 10),
            Leftover(path: "/u/Library/Application Support/a", place: .applicationSupport, size: 20),
            Leftover(path: "/Applications/A.app", place: nil, size: 1),
        ].sorted(by: Leftover.sheetOrder)
        #expect(items.map(\.name) == ["A.app", "a", "a", "a"])
        #expect(items.map(\.category) == [.app, .data, .data, .caches])
        #expect(items[1].size == 20)
    }
}
