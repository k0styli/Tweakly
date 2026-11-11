/// The name of a new file, and the names to try in turn when it is taken, the way Finder names a new folder:
/// "New File.txt", then "New File 2.txt", "New File 3.txt" and so on.
public struct NewFileName: Equatable, Sendable {
    /// Room for the number and the extension within the 255 bytes a name may take.
    public static let maximumBaseBytes = 200
    public static let maximumExtensionLength = 16

    public let base: String
    public let pathExtension: String

    /// Nil when the name could not be a single plain file name: empty, hidden, with a path separator, a control
    /// character or an extension that is more than letters and digits.
    public init?(base: String, pathExtension: String) {
        guard Self.isValidBase(base), Self.isValidExtension(pathExtension) else { return nil }
        self.base = base
        self.pathExtension = pathExtension
    }

    /// The name to try at a given attempt, counting from 1.
    public func candidate(_ attempt: Int) -> String {
        let numbered = attempt <= 1 ? base : "\(base) \(attempt)"
        return pathExtension.isEmpty ? numbered : "\(numbered).\(pathExtension)"
    }

    /// The names to try, in order, up to a limit, so a folder full of new files cannot keep this going for ever.
    public func candidates(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return (1...limit).map(candidate)
    }

    private static func isValidBase(_ base: String) -> Bool {
        // Finder would hide a leading dot, and spaces at either end are easy to miss in a name.
        guard !base.isEmpty, base.utf8.count <= maximumBaseBytes, !base.hasPrefix("."), base.first != " ",
            base.last != " "
        else { return false }
        // A colon is how Finder shows a slash, and the two would be confused.
        return !base.unicodeScalars.contains { $0 == "/" || $0 == ":" || $0.properties.generalCategory == .control }
    }

    private static func isValidExtension(_ pathExtension: String) -> Bool {
        pathExtension.count <= maximumExtensionLength
            && pathExtension.unicodeScalars.allSatisfy {
                $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0)
            }
    }
}
