import AppKit
import CryptoKit
import FanControlCore
import Security

/// Puts the root helper where launchd can start it, which takes an administrator's password once. Runs in the window's
/// process, as the system's request for a password is something a person asked for by pressing a button.
///
/// It uses the system's administrator request rather than `SMAppService`, which has no known way to work with a local
/// signature.
enum FanHelperInstaller {
    private static var bundleID: String { Bundle.main.bundleIdentifier ?? "" }
    private static var label: String { FanHelper.label(forApp: bundleID) }
    private static var plistPath: String { FanHelper.launchdPlist(forApp: bundleID) }
    private static var toolPath: String { "/Library/PrivilegedHelperTools/\(label)" }
    private static var bundledTool: String {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchServices/TweaklyFanHelper").path
    }

    /// Nil when it went well or someone pressed Cancel, otherwise what went wrong. The prompt says what it is for, as the
    /// same helper serves the fans and the task manager.
    static func install(
        prompt: String = String(localized: "Tweakly needs to install a helper to control the fans.")
    ) -> String? {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key><array><string>\(toolPath)</string><string>\(FanHelper.clientArgument)</string><string>\(bundleID)</string></array>
            <key>MachServices</key><dict><key>\(label)</key><true/></dict>
            <key>KeepAlive</key><dict><key>Crashed</key><true/></dict>
            </dict></plist>
            """
        let script = HelperInstallScript.install(
            bundledTool: bundledTool, toolPath: toolPath, plistPath: plistPath, plist: plist, label: label,
            requirement: ownSignerRequirement())
        return run(script, prompt: prompt)
    }

    static func uninstall() -> String? {
        let script = """
            /bin/launchctl bootout system/\(label) 2>/dev/null
            /bin/rm -f \(quoted(plistPath)) \(quoted(toolPath))
            """
        return run(script, prompt: String(localized: "Tweakly needs to remove its fan helper."))
    }

    private static func run(_ script: String, prompt: String) -> String? {
        switch AdministratorPrompt.run(script, prompt: prompt) {
        case .done, .cancelled: nil
        case .failed(let message): message ?? String(localized: "The helper could not be changed.")
        }
    }

    /// What the app itself is signed with, which the helper copied from its bundle must be signed with too: the bundle
    /// can be changed by whoever owns it, and what is installed runs as root.
    private static func ownSignerRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let information = information as? [String: Any]
        else { return nil }
        let leaf = (information[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first.map {
            Insecure.SHA1.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02x", $0) }.joined()
        }
        return HelperInstallScript.signerRequirement(
            team: information[kSecCodeInfoTeamIdentifier as String] as? String, leafCertificateSHA1: leaf)
    }

    private static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}
