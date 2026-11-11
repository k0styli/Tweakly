import Foundation

public enum IconFileError: Error, Equatable, Sendable {
    case tooLarge
    case unreadable
    /// Nothing can be seen in it: every frame is empty or transparent.
    case empty
}

/// An icon as SVG text: one drawing, or several frames in groups marked `data-frame`.
///
/// The system's reader cannot animate and draws a group marked `display="none"` anyway, as checked on macOS 27.2, so each
/// frame becomes a file of its own that holds only that frame. What is not in a frame stays in all of them, which is how
/// parts that do not move can be shared.
public struct IconSVG: Sendable {
    public static let largestFile = 2_000_000
    private static let frameRates: ClosedRange<Double> = 1...60
    /// Anything that could reach outside the file or run something. The system's reader should ignore these, but a file
    /// from a chat or the internet has no reason to contain them, and removing them means not having to find out.
    private static let removedElements: Set<String> = [
        "script", "foreignObject", "image", "feImage", "iframe", "audio", "video", "object", "embed", "animate",
        "animateTransform", "animateMotion", "set",
    ]

    /// One whole SVG file for each frame that is kept. Each costs a copy of the document, so the frames beyond what can be
    /// used are not made at all: a small file can list thousands of them, and each copy can hold a large shared part.
    public let frames: [Data]
    /// How many the file has, which is what its pace goes by.
    public let frameCount: Int
    public let framesPerSecond: Double?

    public init(data: Data) throws {
        guard data.count <= Self.largestFile else { throw IconFileError.tooLarge }
        // Entities are how a small XML file grows into gigabytes, and an icon has no use for them.
        guard !data.contains(Data("<!ENTITY".utf8)) else { throw IconFileError.unreadable }
        guard let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
            let root = document.rootElement(), root.localName == "svg"
        else { throw IconFileError.unreadable }
        // Without any size the system's reader scales the drawing to something useless.
        guard Self.hasSize(root) else { throw IconFileError.unreadable }
        Self.clean(root)
        framesPerSecond = root.attribute(forName: "data-fps")?.stringValue.flatMap(Double.init).flatMap {
            Self.frameRates.contains($0) ? $0 : nil
        }
        let inFileOrder = Self.frameElements(in: root)
        let count = inFileOrder.count
        frameCount = max(count, 1)
        guard count > 1 else {
            frames = [document.xmlData]
            return
        }
        let shownOrder = Self.playingOrder(of: inFileOrder)
        var made: [Data] = []
        for index in IconFit.keptFrames(of: count) {
            guard let copy = document.copy() as? XMLDocument, let copyRoot = copy.rootElement() else {
                throw IconFileError.unreadable
            }
            let chosen = shownOrder[index]
            // From the end of the file back: taking a child from the front moves all the rest, which adds up to minutes
            // for a file with tens of thousands of frames.
            for (position, element) in Self.frameElements(in: copyRoot).enumerated().reversed() {
                if position == chosen {
                    Self.makeVisible(element)
                } else {
                    element.detach()
                }
            }
            made.append(copy.xmlData)
        }
        frames = made
    }

    /// Finds the SVG in what someone copied from a chat, which may come with a code fence or words around it.
    public static func find(inText text: String) -> Data? {
        guard let start = text.range(of: "<svg", options: .caseInsensitive),
            let end = text.range(of: "</svg>", options: [.caseInsensitive, .backwards]),
            start.lowerBound < end.lowerBound
        else { return nil }
        return Data(text[start.lowerBound..<end.upperBound].utf8)
    }

    /// Whether a file should go to this reader rather than to the one for pictures.
    public static func looksLikeSVG(_ data: Data) -> Bool {
        // The cut can fall in the middle of a letter of a valid file, of up to four bytes. Anything else that is not text is
        // a picture, even if its metadata happens to mention SVG.
        let start = data.prefix(4096)
        guard let text = (0...3).lazy.compactMap({ String(data: start.dropLast($0), encoding: .utf8) }).first else {
            return false
        }
        return text.range(of: "<svg", options: .caseInsensitive) != nil
    }

    private static func hasSize(_ root: XMLElement) -> Bool {
        root.attribute(forName: "viewBox") != nil
            || (root.attribute(forName: "width") != nil && root.attribute(forName: "height") != nil)
    }

    private static func clean(_ element: XMLElement) {
        for attribute in element.attributes ?? [] {
            guard let name = attribute.localName ?? attribute.name else { continue }
            let value = attribute.stringValue ?? ""
            let reachesOutside = name == "href" && !value.hasPrefix("#")
            if name.lowercased().hasPrefix("on") || reachesOutside || hasOutsideLink(value) {
                element.removeAttribute(forName: attribute.name ?? name)
            }
        }
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            let name = child.localName ?? child.name ?? ""
            let isBadStyle = name == "style" && hasOutsideLink(child.stringValue ?? "")
            if removedElements.contains(name) || isBadStyle {
                child.detach()
            } else {
                clean(child)
            }
        }
    }

    /// A link to something in this same file, as in `url(#shape)`, is fine.
    private static func hasOutsideLink(_ text: String) -> Bool {
        let lowered = text.lowercased().replacingOccurrences(of: " ", with: "")
        if lowered.contains("@import") { return true }
        var rest = lowered[...]
        while let range = rest.range(of: "url(") {
            rest = rest[range.upperBound...]
            let next = rest.drop { $0 == "\"" || $0 == "'" }.first
            if next != "#" { return true }
        }
        return false
    }

    /// In the order of the file. Accepts a wrapper around them too, which models like to add however clearly they are told
    /// not to.
    private static func frameElements(in root: XMLElement) -> [XMLElement] {
        let direct = (root.children ?? []).compactMap { $0 as? XMLElement }
        let found = direct.filter { frameNumber(of: $0) != nil }
        guard found.isEmpty, direct.filter({ $0.localName == "g" }).count == 1,
            let wrapper = direct.first(where: { $0.localName == "g" })
        else { return found }
        return (wrapper.children ?? []).compactMap { $0 as? XMLElement }.filter { frameNumber(of: $0) != nil }
    }

    /// Where each frame is in the file, in order of their numbers, as a model may well write them in some other order.
    private static func playingOrder(of elements: [XMLElement]) -> [Int] {
        let numbers: [Int] = elements.enumerated().map { frameNumber(of: $0.element) ?? $0.offset }
        return numbers.indices.sorted { numbers[$0] == numbers[$1] ? $0 < $1 : numbers[$0] < numbers[$1] }
    }

    private static func frameNumber(of element: XMLElement) -> Int? {
        if let value = element.attribute(forName: "data-frame")?.stringValue { return Int(value) ?? 0 }
        guard let id = element.attribute(forName: "id")?.stringValue?.lowercased(), id.hasPrefix("frame") else {
            return nil
        }
        return Int(id.dropFirst(5).drop { $0 == "-" || $0 == "_" })
    }

    private static let hidingProperties = ["display", "visibility", "opacity"]

    private static func makeVisible(_ element: XMLElement) {
        for name in hidingProperties { element.removeAttribute(forName: name) }
        guard let style = element.attribute(forName: "style")?.stringValue else { return }
        // What else it says still counts, such as the frame's colour.
        let kept = style.split(separator: ";").filter { declaration in
            let name = declaration.split(separator: ":").first?.trimmingCharacters(in: .whitespaces).lowercased()
            return !hidingProperties.contains(name ?? "")
        }
        element.removeAttribute(forName: "style")
        if !kept.isEmpty,
            let attribute = XMLNode.attribute(withName: "style", stringValue: kept.joined(separator: ";")) as? XMLNode
        {
            element.addAttribute(attribute)
        }
    }
}
