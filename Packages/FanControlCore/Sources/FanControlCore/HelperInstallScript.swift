import Foundation

/// The shell script that puts the root helper where launchd starts it, run behind the system's request for a password.
///
/// The copy goes to a new name next to the old one, is checked there and only then renamed over it. Copying straight
/// over a helper that has run rewrites the file the kernel still holds the old signature of, so the new helper is killed
/// for an invalid signature at every start, and launchd starts it again and again until a restart. A rename gives the
/// file a new identity. The check is made on the root-owned copy, so the bundle, which its owner can change, cannot be
/// swapped between the check and the use.
public enum HelperInstallScript {
    /// What a helper must be signed with to be installed: what the app itself is signed with. A Developer ID of the
    /// same team, so a renewed certificate still installs, or the same certificate on a development Mac. Nil for a copy
    /// with no certificate, whose helper could not tell who asks anyway.
    public static func signerRequirement(team: String?, leafCertificateSHA1: String?) -> String? {
        if let team, !team.isEmpty {
            // Apple's own fields for a Developer ID intermediate and leaf, as in the designated requirement codesign
            // writes.
            return "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
                + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
                + "and certificate leaf[subject.OU] = \"\(team)\""
        }
        if let leafCertificateSHA1, !leafCertificateSHA1.isEmpty {
            return "certificate leaf = H\"\(leafCertificateSHA1)\""
        }
        return nil
    }

    /// - Parameters:
    ///   - owner: `root:wheel` for real; a test passes its own user, as it cannot give files to root.
    ///   - launchd: Stops the old helper first and starts the new one; off in a test.
    public static func install(
        bundledTool: String, toolPath: String, plistPath: String, plist: String, label: String,
        requirement: String?, owner: String = "root:wheel", launchd: Bool = true
    ) -> String {
        let tool = quoted(toolPath)
        let new = quoted(toolPath + ".new")
        let folder = quoted((toolPath as NSString).deletingLastPathComponent)
        let check = requirement.map { " -R=\(quoted($0))" } ?? ""
        var lines: [String] = []
        if launchd { lines.append("/bin/launchctl bootout system/\(quoted(label)) 2>/dev/null") }
        lines += [
            "set -e",
            "/bin/mkdir -p \(folder)",
            "/bin/rm -f \(new)",
            "/bin/cp \(quoted(bundledTool)) \(new)",
            "/usr/sbin/chown \(owner) \(new)",
            "/bin/chmod 544 \(new)",
            "/usr/bin/codesign --verify --strict\(check) \(new) || { /bin/rm -f \(new); exit 65; }",
            "/bin/mv -f \(new) \(tool)",
            "/bin/cat > \(quoted(plistPath)) <<'PLIST'",
            plist,
            "PLIST",
            "/usr/sbin/chown \(owner) \(quoted(plistPath))",
            "/bin/chmod 644 \(quoted(plistPath))",
        ]
        if launchd { lines.append("/bin/launchctl bootstrap system \(quoted(plistPath))") }
        return lines.joined(separator: "\n")
    }

    /// In single quotes, which the shell takes literally, with each quote of the text closed, escaped and reopened.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
