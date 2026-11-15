import Darwin
import Testing

@testable import SystemMetrics

/// The popovers' lists add up an app as the task manager does, which these pin down on made-up processes.
@Suite struct ProcessOwnerTests {
    private static let user = getuid()
    private static let editor = "/Applications/Editor.app"
    private static let safari = "/Applications/Safari.app"
    private static let parallels = "/Applications/Parallels Desktop.app"

    private static let processes: [Int32: (identity: ProcessIdentity, path: String)] = [
        100: identity("Editor", editor + "/Contents/MacOS/Editor", parent: 1),
        101: identity(
            "Editor Helper (Renderer)",
            editor + "/Contents/Frameworks/Editor Helper (Renderer).app/Contents/MacOS/Editor Helper (Renderer)",
            parent: 100),
        // Editor starts its agent, which has a bundle of its own, through a helper that disclaims responsibility.
        104: identity("disclaimer", editor + "/Contents/Helpers/disclaimer", parent: 100),
        102: identity(
            "agent", "/Users/me/Library/Application Support/Editor/agent/2.0/agent.app/Contents/MacOS/agent",
            parent: 104),
        103: identity("zsh", "/bin/zsh", parent: 102),
        105: identity("swift-build", "/usr/bin/swift-build", parent: 103),
        200: identity(
            "com.apple.WebKit.WebContent",
            "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
            parent: 1),
        300: identity("Safari", safari + "/Contents/MacOS/Safari", parent: 1),
        400: identity("trustd", "/usr/libexec/trustd", parent: 1),
        500: identity(
            "WindowServer", "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer",
            parent: 1, user: 88),
        // Parallels: the app is the person's, its service and the virtual machine it starts run as root.
        700: identity("prl_client_app", parallels + "/Contents/MacOS/prl_client_app", parent: 1),
        701: identity(
            "prl_disp_service", parallels + "/Contents/MacOS/Parallels Service.app/Contents/MacOS/prl_disp_service",
            parent: 1, user: 0),
        702: identity(
            "prl_vm_app", parallels + "/Contents/MacOS/Parallels VM.app/Contents/MacOS/prl_vm_app", parent: 701, user: 0
        ),
        600: identity("ghost", "/usr/bin/ghost", parent: 601),
        601: identity("ghost", "/usr/bin/ghost", parent: 600),
    ]

    private static func identity(_ name: String, _ path: String, parent: Int32, user: UInt32 = user) -> (
        identity: ProcessIdentity, path: String
    ) {
        (ProcessIdentity(shortName: name, parentPID: parent, userID: user, start: UInt64(parent) * 1000 + 7), path)
    }

    /// The service launchd starts for Safari names Safari as responsible, and a shell the agent runs names the agent.
    private func identities(responsible: [Int32: Int32] = [103: 102, 105: 102, 200: 300]) -> ProcessIdentities {
        ProcessIdentities(
            lookups: .init(
                identity: { Self.processes[$0]?.identity },
                path: { Self.processes[$0]?.path },
                responsible: { responsible[$0] },
                appName: { String($0.split(separator: "/").last?.dropLast(4) ?? "") }
            ))
    }

    @Test func helpersAndWhatTheAppStartedCountTowardsIt() {
        var identities = identities()
        for pid: Int32 in [100, 101, 102, 103, 104, 105] {
            let owner = identities.owner(of: pid)
            #expect(owner.key == .app(Self.editor), "process \(pid)")
            #expect(identities.name(of: owner) == "Editor")
        }
    }

    @Test func aServiceLaunchdStartedForAnAppCountsTowardsIt() {
        var identities = identities()
        #expect(identities.owner(of: 200).bundlePath == Self.safari)
    }

    @Test func withoutTheResponsibleAppParentsStillGroupButAServiceStandsAlone() {
        var identities = identities(responsible: [:])
        #expect(identities.owner(of: 105).bundlePath == Self.editor)
        #expect(identities.owner(of: 102).bundlePath == Self.editor)
        #expect(identities.owner(of: 200).key == .process(200))
    }

    @Test func aDaemonStandsAloneUnderItsOwnName() {
        var identities = identities()
        let owner = identities.owner(of: 400)
        #expect(owner.key == .process(400))
        #expect(identities.name(of: owner) == "trustd")
    }

    @Test func aLoopInStaleParentsEnds() {
        var identities = identities()
        #expect(identities.owner(of: 600).key == .process(600))
    }

    @Test func theRowIsHeadedByTheAppsOwnProcess() {
        var identities = identities()
        let owner = identities.owner(of: 101)
        let entry = identities.entry(for: owner, pids: [103, 101, 102, 100])
        #expect(entry.pid == 100, "not the agent, which is the main process of a bundle too")
        #expect(entry.path == Self.editor + "/Contents/MacOS/Editor")
        #expect(entry.members.map(\.pid) == [100, 101, 102, 103])
        #expect(entry.processCount == 4)
        #expect(entry.appBundlePath == Self.editor)
        #expect(entry.canEnd)
    }

    @Test func helpersAloneStillStandForTheirApp() {
        var identities = identities()
        let entry = identities.entry(for: identities.owner(of: 101), pids: [101])
        #expect(entry.name == "Editor")
        #expect(entry.appBundlePath == Self.editor)
    }

    @Test func onlyThePersonsOwnProcessesCanBeEnded() {
        var identities = identities()
        #expect(!identities.entry(for: identities.owner(of: 500), pids: [500]).canEnd)
        #expect(identities.entry(for: identities.owner(of: 400), pids: [400]).canEnd)
    }

    /// The person's app quits by its own command and ends what it runs as root itself.
    @Test func thePersonsAppCanBeEndedWithWhatItRunsAsRoot() {
        var identities = identities()
        let owner = identities.owner(of: 702)
        #expect(owner.bundlePath == Self.parallels)
        #expect(identities.entry(for: owner, pids: [702, 701, 700]).canEnd)
        #expect(!identities.entry(for: owner, pids: [701, 702]).canEnd, "without the app's own process, only signals")
    }

    @Test func thisAppCannotEndItself() {
        var identities = ProcessIdentities()
        let own = getpid()
        #expect(!identities.entry(for: identities.owner(of: own), pids: [own]).canEnd)
    }

    @Test func aNumberHandedOnIsNotTheSameProcess() {
        var identities = ProcessIdentities()
        let own = identities.identity(of: getpid())
        #expect(own.start > 0)
        #expect(ProcessMember(pid: getpid(), start: own.start).isRunning)
        #expect(!ProcessMember(pid: getpid(), start: own.start + 1).isRunning)
    }
}
