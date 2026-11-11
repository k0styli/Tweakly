import Testing

@testable import FinderMenuCore

@Suite struct NewFileNameTests {
    @Test func namesFollowFindersNewFolder() throws {
        let name = try #require(NewFileName(base: "Новый файл", pathExtension: "txt"))
        #expect(name.candidates(limit: 3) == ["Новый файл.txt", "Новый файл 2.txt", "Новый файл 3.txt"])
    }

    @Test func noExtensionMeansNoDot() throws {
        let name = try #require(NewFileName(base: "untitled file", pathExtension: ""))
        #expect(name.candidate(1) == "untitled file")
        #expect(name.candidate(12) == "untitled file 12")
    }

    @Test func noCandidatesWithoutALimit() throws {
        let name = try #require(NewFileName(base: "a", pathExtension: "md"))
        #expect(name.candidates(limit: 0).isEmpty)
    }

    @Test(arguments: ["", ".hidden", "a/b", "a:b", " lead", "trail ", "tab\there", "line\nbreak", "nul\u{0}"])
    func refusesNamesThatAreNotOneVisibleFile(_ base: String) {
        #expect(NewFileName(base: base, pathExtension: "txt") == nil)
    }

    @Test func refusesNamesTooLongForANumberAndExtension() {
        #expect(NewFileName(base: String(repeating: "a", count: 200), pathExtension: "txt") != nil)
        #expect(NewFileName(base: String(repeating: "a", count: 201), pathExtension: "txt") == nil)
        // Cyrillic letters take two bytes each.
        #expect(NewFileName(base: String(repeating: "ф", count: 101), pathExtension: "txt") == nil)
    }

    @Test(arguments: ["txt", "md", "MP4", "h264", ""])
    func acceptsPlainExtensions(_ pathExtension: String) {
        #expect(NewFileName(base: "a", pathExtension: pathExtension) != nil)
    }

    @Test(arguments: ["t.xt", "tx t", "тxt", "a/b", ".txt", String(repeating: "a", count: 17)])
    func refusesOtherExtensions(_ pathExtension: String) {
        #expect(NewFileName(base: "a", pathExtension: pathExtension) == nil)
    }
}

@Suite struct FolderPathTests {
    @Test(arguments: ["/", "/Users/me/Desktop", "/Volumes/Диск/папка с пробелом", "/a/b.c/..d/.e"])
    func acceptsPlainAbsolutePaths(_ path: String) {
        #expect(FolderPath.validated(path) == path)
    }

    @Test(arguments: [
        "", "relative/path", "~/Desktop", "/a/../b", "/a/./b", "/..", "/a//b", "/a/", "//a", "/a\nb", "/a\u{0}b",
    ])
    func refusesAnythingThatNeedsResolving(_ path: String) {
        #expect(FolderPath.validated(path) == nil)
    }

    @Test func refusesOverLongPaths() {
        let long = "/" + String(repeating: "a", count: FinderMenuWire.maximumPathBytes)
        #expect(FolderPath.validated(long) == nil)
        #expect(FolderPath.validated(String(long.dropLast())) != nil)
    }
}

@Suite struct FinderMenuWireTests {
    private func roundTrip(_ request: FinderMenuRequest) -> FinderMenuRequest? {
        let (id, body) = FinderMenuWire.encode(request)
        return FinderMenuWire.decode(id: id, body: body)
    }

    /// The length first, then the strings, then zeros to a whole number of 4 bytes.
    private func body(_ strings: String) -> [UInt8] {
        let bytes = Array(strings.utf8)
        return withUnsafeBytes(of: UInt32(bytes.count).littleEndian, Array.init) + bytes
            + [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4)
    }

    @Test func requestsSurviveTheTrip() throws {
        let name = try #require(NewFileName(base: "Новый файл", pathExtension: "txt"))
        let requests: [FinderMenuRequest] = [
            .items, .newFile(folder: "/Users/me/Рабочий стол", name: name), .openInTerminal(path: "/tmp/a b"),
        ]
        for request in requests {
            #expect(roundTrip(request) == request)
        }
    }

    @Test func bodiesAreWholeWordsWithAnEmptyLastString() throws {
        // An empty extension ends in two zero bytes, which padding alone would make ambiguous.
        let name = try #require(NewFileName(base: "a", pathExtension: ""))
        for request in [FinderMenuRequest.items, .newFile(folder: "/b", name: name), .openInTerminal(path: "/abc")] {
            let (_, body) = FinderMenuWire.encode(request)
            #expect(body.count % 4 == 0)
            #expect(roundTrip(request) == request)
        }
    }

    @Test func unknownKindsAreRefused() {
        #expect(FinderMenuWire.decode(id: 0x5477_4600, body: body("")) == nil)
        #expect(FinderMenuWire.decode(id: 1, body: body("")) == nil)
    }

    @Test func framingMustAddUp() {
        let terminal = FinderMenuWire.Kind.openInTerminal.rawValue
        #expect(FinderMenuWire.decode(id: terminal, body: body("/tmp\0")) == .openInTerminal(path: "/tmp"))
        // No length at all.
        #expect(FinderMenuWire.decode(id: terminal, body: [1, 0]) == nil)
        // A length past the end.
        #expect(FinderMenuWire.decode(id: terminal, body: [9, 0, 0, 0] + Array("/a\0".utf8)) == nil)
        // More than padding after the strings.
        #expect(FinderMenuWire.decode(id: terminal, body: body("/tmp\0") + [0, 0, 0, 0]) == nil)
        // Padding that is not zeros.
        #expect(FinderMenuWire.decode(id: terminal, body: [3, 0, 0, 0] + Array("/a\0".utf8) + [7]) == nil)
    }

    @Test func malformedPayloadsAreRefused() {
        let terminal = FinderMenuWire.Kind.openInTerminal.rawValue
        let newFile = FinderMenuWire.Kind.newFile.rawValue
        // Not ended by a zero byte.
        #expect(FinderMenuWire.decode(id: terminal, body: body("/tmp")) == nil)
        // Two paths where one is expected.
        #expect(FinderMenuWire.decode(id: terminal, body: body("/a\0/b\0")) == nil)
        // A relative path.
        #expect(FinderMenuWire.decode(id: terminal, body: body("tmp\0")) == nil)
        // Not UTF-8.
        #expect(FinderMenuWire.decode(id: terminal, body: [3, 0, 0, 0, 0x2F, 0xFF, 0, 0]) == nil)
        // A name with a slash, which would write somewhere else.
        #expect(FinderMenuWire.decode(id: newFile, body: body("/tmp\0../x\0txt\0")) == nil)
        // Items asks nothing.
        #expect(FinderMenuWire.decode(id: FinderMenuWire.Kind.items.rawValue, body: body("\0")) == nil)
    }

    @Test func oversizedPayloadsAreRefused() {
        let path = "/" + String(repeating: "a", count: FinderMenuWire.maximumBody)
        #expect(FinderMenuWire.decode(id: FinderMenuWire.Kind.openInTerminal.rawValue, body: body(path + "\0")) == nil)
    }

    @Test func itemsSurviveTheTrip() {
        for items: FinderMenuItems in [[], .all, [.newFile], [.copyPath, .openInTerminal]] {
            #expect(FinderMenuWire.decodeItems(FinderMenuWire.encode(items)) == items)
        }
    }

    @Test func unknownItemBitsAreDropped() {
        #expect(FinderMenuWire.decodeItems([0xFF, 0xFF, 0xFF, 0xFF]) == .all)
        #expect(FinderMenuWire.decodeItems([1, 0, 0]) == nil)
    }

    @Test func serviceIsNamedAfterTheApp() {
        #expect(FinderMenuWire.serviceName(forApp: "me.tweakly.Tweakly") == "me.tweakly.Tweakly.finder-menu")
        #expect(FinderMenuWire.appBundleID(forExtension: "me.tweakly.Tweakly.FinderMenu") == "me.tweakly.Tweakly")
        #expect(
            FinderMenuWire.appBundleID(forExtension: "me.tweakly.Tweakly.perf.FinderMenu")
                == "me.tweakly.Tweakly.perf"
        )
        #expect(FinderMenuWire.appBundleID(forExtension: "me.tweakly.Tweakly") == nil)
        #expect(FinderMenuWire.appBundleID(forExtension: ".FinderMenu") == nil)
    }
}

@Suite struct FinderMenuActionTests {
    @Test func terminalOpensInAFolderOrBesideAFile() {
        #expect(TerminalTarget.folder(for: "/Users/me/Projects", kind: .folder) == "/Users/me/Projects")
        #expect(TerminalTarget.folder(for: "/Users/me/notes.txt", kind: .file) == "/Users/me")
        #expect(TerminalTarget.folder(for: "/Applications/Safari.app", kind: .package) == "/Applications")
        #expect(TerminalTarget.folder(for: "/file", kind: .file) == "/")
        #expect(TerminalTarget.folder(for: "/", kind: .folder) == "/")
    }

    @Test func pathsAreCopiedOneALine() {
        #expect(CopiedPaths.text(for: ["/a"]) == "/a")
        #expect(CopiedPaths.text(for: ["/a", "/b c"]) == "/a\n/b c")
    }

    @Test func newFileOnlyWhereNewFolderIs() {
        #expect(FinderMenuPlace.container.shows(.all) == .all)
        #expect(FinderMenuPlace.items.shows(.all) == [.copyPath, .openInTerminal])
        #expect(FinderMenuPlace.sidebar.shows([.newFile]) == [])
    }
}
