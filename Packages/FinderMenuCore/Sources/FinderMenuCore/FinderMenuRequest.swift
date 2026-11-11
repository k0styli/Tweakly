/// What the Finder extension asks of the agent. The extension is sandboxed and can neither write into the folder
/// someone clicked nor start a terminal there, so it passes those on.
public enum FinderMenuRequest: Equatable, Sendable {
    /// Which items to show. The agent answers only while the tweak is on, so silence means no items.
    case items
    case newFile(folder: String, name: NewFileName)
    /// A folder, or a file, whose folder is meant.
    case openInTerminal(path: String)
}

/// How a request travels between the two processes: a message ID for its kind, and a body of the length of its strings,
/// the strings as UTF-8 each ended by a zero byte, and zeros up to a whole number of 4 bytes, which a Mach message must
/// be. Without the length, that padding could not be told from an empty last string. A message that does not decode
/// exactly is refused whole.
public enum FinderMenuWire {
    /// Far above any real path, and small enough that a message never needs memory of its own.
    public static let maximumBody = 4096
    private static let lengthSize = 4
    public static let maximumPathBytes = 1024

    enum Kind: Int32 {
        // "TwFM" and a number, so a stray message cannot be mistaken for one of these.
        case items = 0x5477_4601
        case newFile = 0x5477_4602
        case openInTerminal = 0x5477_4603
    }

    /// The Mach service the agent registers while the tweak is on, named after the app so a test copy has its own.
    public static func serviceName(forApp bundleID: String) -> String {
        bundleID + ".finder-menu"
    }

    /// The app's identifier from the extension's, which is the app's with this suffix.
    public static func appBundleID(forExtension bundleID: String) -> String? {
        let suffix = ".FinderMenu"
        guard bundleID.hasSuffix(suffix), bundleID.count > suffix.count else { return nil }
        return String(bundleID.dropLast(suffix.count))
    }

    public static func encode(_ request: FinderMenuRequest) -> (id: Int32, body: [UInt8]) {
        switch request {
        case .items: (Kind.items.rawValue, framed([]))
        case .newFile(let folder, let name):
            (Kind.newFile.rawValue, framed([folder, name.base, name.pathExtension]))
        case .openInTerminal(let path): (Kind.openInTerminal.rawValue, framed([path]))
        }
    }

    public static func decode(id: Int32, body: some Collection<UInt8>) -> FinderMenuRequest? {
        guard let kind = Kind(rawValue: id), body.count <= maximumBody, let parts = strings(inFramed: Array(body))
        else { return nil }
        switch kind {
        case .items:
            return parts.isEmpty ? .items : nil
        case .newFile:
            guard parts.count == 3, let folder = FolderPath.validated(parts[0]),
                let name = NewFileName(base: parts[1], pathExtension: parts[2])
            else { return nil }
            return .newFile(folder: folder, name: name)
        case .openInTerminal:
            guard parts.count == 1, let path = FolderPath.validated(parts[0]) else { return nil }
            return .openInTerminal(path: path)
        }
    }

    /// The answer to `.items`.
    public static func encode(_ items: FinderMenuItems) -> [UInt8] {
        withUnsafeBytes(of: items.rawValue.littleEndian, Array.init)
    }

    public static func decodeItems(_ bytes: some BidirectionalCollection<UInt8>) -> FinderMenuItems? {
        guard bytes.count == 4 else { return nil }
        let value = bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return FinderMenuItems(rawValue: value).intersection(.all)
    }

    private static func framed(_ parts: [String]) -> [UInt8] {
        let strings: [UInt8] = parts.flatMap { Array($0.utf8) + [0] }
        let length = withUnsafeBytes(of: UInt32(strings.count).littleEndian, Array.init)
        let padding = (4 - strings.count % 4) % 4
        return length + strings + [UInt8](repeating: 0, count: padding)
    }

    private static func strings(inFramed body: [UInt8]) -> [String]? {
        guard body.count >= lengthSize else { return nil }
        let length = Int(body[..<lengthSize].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        let end = lengthSize + length
        // Exactly the padding after the strings, and nothing but zeros in it.
        guard length <= body.count - lengthSize, body.count - end < 4, body[end...].allSatisfy({ $0 == 0 }) else {
            return nil
        }
        return strings(in: body[lengthSize..<end])
    }

    private static func strings(in payload: ArraySlice<UInt8>) -> [String]? {
        guard let last = payload.last else { return [] }
        guard last == 0 else { return nil }
        var parts: [String] = []
        for bytes in payload.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
            // Refuses bytes that are not UTF-8 rather than letting them turn into replacement characters.
            guard let part = String(validating: bytes, as: UTF8.self) else { return nil }
            parts.append(part)
        }
        return parts
    }
}

/// A path the agent will act on. Finder sends plain absolute paths, so anything else is refused rather than resolved:
/// relative parts, repeated or trailing slashes and over-long paths.
public enum FolderPath {
    public static func validated(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= FinderMenuWire.maximumPathBytes,
            !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        if path == "/" { return path }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return path
    }
}
