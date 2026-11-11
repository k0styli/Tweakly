import Foundation
import UninstallerCore

/// The page's words for what the table and the sheet show.
enum UninstallerText {
    /// As the approved draft of the page has it: a duplicate first, then where the app comes from, then its processors,
    /// as System Settings names them.
    nonisolated static func kind(of app: InstalledApp) -> String {
        if app.isDuplicate { return String(localized: "Duplicate", comment: "Kind of an app that is a second copy") }
        if app.isAppStore { return "App Store" }
        switch app.kind {
        case .appleSilicon: return String(localized: "Apple Silicon", comment: "Kind of an app, as in System Settings")
        case .universal: return String(localized: "Universal", comment: "Kind of an app, as in System Settings")
        case .intel: return "Intel"
        case .unknown: return String(localized: "Other")
        }
    }

    static func category(_ category: LeftoverCategory) -> String {
        switch category {
        case .app: String(localized: "App", comment: "Kind of a file in the removal sheet: the app itself")
        case .data: String(localized: "Data", comment: "Kind of a file in the removal sheet")
        case .caches: String(localized: "Cache", comment: "Kind of a file in the removal sheet")
        case .settings: String(localized: "Settings", comment: "Kind of a file in the removal sheet")
        case .savedState: String(localized: "Window State", comment: "Kind of a file in the removal sheet")
        case .logs: String(localized: "Logs", comment: "Kind of a file in the removal sheet")
        case .background: String(localized: "Background Item", comment: "A launch agent, daemon or helper")
        }
    }

    static func done(_ mode: RemovalPlan.Mode, name: String, size: Int64) -> String {
        let size = Format.fileSize(UInt64(max(size, 0)))
        return switch mode {
        case .uninstall: String(localized: "“\(name)” was moved to the Trash: \(size).")
        case .reset: String(localized: "The data of “\(name)” was moved to the Trash: \(size).")
        }
    }

    static func failed(count: Int) -> String {
        String(localized: "\(count) items did not reach the Trash. They are listed above.")
    }

    static func size(_ bytes: Int64?) -> String {
        bytes.map { Format.fileSize(UInt64(max($0, 0))) } ?? "—"
    }

    /// A path as Finder would show it to its owner, with the home folder as `~`.
    static func shortPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
