import AppKit
import TaskManagerCore
import os

/// Ending processes, politely or by force, as End Task and Force Quit do in Windows. Every call here follows a person's
/// click in a dialog that names the process.
///
/// An app is asked to quit as Quit in its menu would, so it can offer to save. Any other process gets `SIGTERM`, which
/// asks it to finish, or `SIGKILL`, which cannot be refused. Another user's process is ended by the root helper where it
/// is installed, one process number at a time, and otherwise with an administrator's password, which the system asks
/// for, as Activity Monitor does.
enum ProcessActions {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "task-manager")

    /// The kernel and launchd: ending either is impossible or takes the whole Mac down.
    static func canEnd(_ pid: Int32) -> Bool { pid > 1 }

    /// Ending these logs the person out, which they should hear about first.
    static func endsSession(_ usage: ProcessUsage) -> Bool {
        ["WindowServer", "loginwindow"].contains(usage.name)
    }

    /// Ends a whole group: the app, which takes its helpers with it, or each process of a group with no app.
    static func end(group: ProcessGroup, force: Bool) {
        if isStillRunning(group.head), let app = NSRunningApplication(processIdentifier: group.head.pid),
            !app.isTerminated
        {
            let asked = force ? app.forceTerminate() : app.terminate()
            if asked { return }
        }
        end([group.head] + group.members, force: force)
    }

    static func end(process usage: ProcessUsage, force: Bool) {
        end([usage], force: force)
    }

    /// Whether a process belongs to macOS or another user, which ending can take more down with it.
    static func isSystem(_ usage: ProcessUsage) -> Bool { usage.userID != getuid() }

    private static func end(_ usages: [ProcessUsage], force: Bool) {
        let signal = force ? SIGKILL : SIGTERM
        var refused: [ProcessUsage] = []
        for usage in usages where canEnd(usage.pid) && isStillRunning(usage) {
            if kill(usage.pid, signal) != 0 {
                if errno == EPERM { refused.append(usage) }
                log.notice("Could not end \(usage.pid, privacy: .public): \(errno, privacy: .public)")
            }
        }
        guard !refused.isEmpty else { return }
        Task {
            let helper = SystemProcessHelper()
            guard await helper.state() == .working else {
                endWithAdministratorRights(refused.map(\.pid), signal: signal)
                return
            }
            for usage in refused {
                if let error = await helper.end(usage.pid, start: usage.key.start, force: force) {
                    log.error("The helper did not end \(usage.pid, privacy: .public): \(error, privacy: .public)")
                }
            }
        }
    }

    /// Whether the number still names the process the person chose. The dialog can stay open while the list moves on,
    /// and a process that ended meanwhile may have handed its number to another of theirs. Another user's process
    /// cannot be asked here; the helper checks that one for itself.
    private static func isStillRunning(_ usage: ProcessUsage) -> Bool {
        guard usage.key.start != 0 else { return true }
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(usage.pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return true }
        if info.ri_proc_start_abstime != usage.key.start {
            log.notice("Process \(usage.pid, privacy: .public) is another one now, so it was left alone")
            return false
        }
        return true
    }

    /// The system's own request for a password, with the command spelled out in it. Numbers only, so nothing in a
    /// process's name can reach the shell.
    private static func endWithAdministratorRights(_ pids: [Int32], signal: Int32) {
        let list = pids.map(String.init).joined(separator: " ")
        let prompt = String(localized: "Tweakly needs an administrator’s password to end a process of another user.")
        if case .failed(let message) = AdministratorPrompt.run("/bin/kill -\(signal) \(list)", prompt: prompt) {
            log.error("Ending with administrator rights failed: \(message ?? "no reason", privacy: .public)")
        }
    }

    /// Activity Monitor's question, with End Task first because it is what most people mean.
    static func confirm(
        name: String, processCount: Int, logsOut: Bool, isSystem: Bool, force: Bool, in window: NSWindow,
        done: @escaping (_ force: Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = logsOut ? .critical : .warning
        alert.messageText =
            force
            ? String(localized: "Force quit “\(name)”?") : String(localized: "End “\(name)”?")
        var details: [String] = []
        if isSystem {
            details.append(
                String(
                    localized:
                        "“\(name)” belongs to macOS or another user. Ending it can stop macOS or other apps from working until you restart."
                ))
        }
        if processCount > 1 { details.append(String(localized: "All \(processCount) of its processes will end.")) }
        details.append(
            force
                ? String(localized: "Unsaved changes will be lost.")
                : String(localized: "An app can ask to save changes first. Force Quit ends it at once."))
        if logsOut { details.append(String(localized: "You will be logged out of your account.")) }
        // Japanese and Chinese end a sentence with a full-width stop and put no space after it.
        let language = Bundle.main.preferredLocalizations.first ?? ""
        let spaced = !(language.hasPrefix("ja") || language.hasPrefix("zh"))
        alert.informativeText = details.joined(separator: spaced ? " " : "")
        if force {
            alert.addButton(withTitle: String(localized: "Force Quit"))
        } else {
            alert.addButton(withTitle: String(localized: "End Task"))
            alert.addButton(withTitle: String(localized: "Force Quit"))
        }
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: done(force)
            case .alertSecondButtonReturn where !force: done(true)
            default: break
            }
        }
    }
}
