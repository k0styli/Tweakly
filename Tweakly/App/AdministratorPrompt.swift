import AppKit

/// The system's own request for an administrator's password, with one shell script behind it. The uninstaller's system
/// files, the fan helper's installation and ending another user's process go through it, and nothing else runs as root
/// this way. Cancelling the request runs nothing.
enum AdministratorPrompt {
    enum Outcome {
        /// What the script printed.
        case done(String)
        case cancelled
        /// The system's reason, where it gave one.
        case failed(String?)
    }

    static func run(_ script: String, prompt: String) -> Outcome {
        let source =
            "do shell script \(appleScriptString(script)) with prompt \(appleScriptString(prompt)) with administrator privileges"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return .done(result?.stringValue ?? "") }
        // -128 is the person pressing Cancel, which is no failure.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String)
    }

    /// In AppleScript's double quotes, with its backslashes and quotes escaped.
    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
