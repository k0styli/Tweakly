import Foundation
import Testing

@testable import LiveWallpaperCore

func wallpaper(
    _ id: String, title: String = "Video", kind: Wallpaper.Kind = .video, origin: Wallpaper.Origin = .downloaded,
    site: String? = nil, width: Int = 1920, height: Int = 1080
) -> Wallpaper {
    Wallpaper(
        id: id, kind: kind, origin: origin, title: title, site: site, width: width, height: height,
        duration: kind == .video ? 10 : 0)
}

@Suite struct ShapeAndSharpnessTests {
    @Test(arguments: [
        (1920, 1080, AspectRatio.standard), (2560, 1600, .standard), (1440, 1080, .standard),
        (2560, 1080, .wide), (3440, 1440, .wide), (5120, 1440, .superWide), (1080, 1920, .portrait),
        (1080, 1080, .square), (0, 0, .standard),
    ])
    func shapes(width: Int, height: Int, expected: AspectRatio) {
        #expect(AspectRatio(width: width, height: height) == expected)
    }

    @Test(arguments: [
        (3840, 2160, Resolution.ultraHD), (4096, 2160, .ultraHD), (3840, 2026, .ultraHD), (2560, 1440, .quadHD),
        (3440, 1440, .quadHD), (5120, 1440, .quadHD), (1920, 1080, .fullHD), (2560, 1080, .fullHD), (1280, 720, .hd),
        (640, 360, .low), (1080, 1920, .fullHD),
    ])
    func resolution(width: Int, height: Int, expected: Resolution) {
        #expect(Resolution(width: width, height: height) == expected)
    }
}

@Suite struct FilterTests {
    let items = [
        wallpaper("lake", title: "Mountain Lake", site: "pexels.com", width: 3840, height: 2160),
        wallpaper("city", title: "Night City", site: "moewalls.com"),
        wallpaper("tall", title: "Waterfall Ана Пе́рес", site: "moewalls.com", width: 1080, height: 1920),
        wallpaper("photo", title: "Dunes", kind: .picture, site: "wallhaven.cc", width: 5120, height: 2880),
        wallpaper("mine", title: "Holiday", origin: .imported, width: 2560, height: 1080),
    ]

    func ids(_ filter: WallpaperFilter, favourites: Set<String> = []) -> [String] {
        filter.apply(to: items, favourites: favourites).map(\.id)
    }

    @Test func everythingWithoutAFilter() {
        #expect(ids(WallpaperFilter()) == ["lake", "city", "tall", "photo", "mine"])
        #expect(!WallpaperFilter().narrows)
    }

    @Test func collections() {
        #expect(ids(WallpaperFilter(collection: .favourites), favourites: ["city", "mine"]) == ["city", "mine"])
        #expect(ids(WallpaperFilter(collection: .downloaded)) == ["lake", "city", "tall", "photo"])
        #expect(ids(WallpaperFilter(collection: .imported)) == ["mine"])
    }

    @Test func kindSiteShapeAndSharpness() {
        #expect(ids(WallpaperFilter(kind: .picture)) == ["photo"])
        #expect(ids(WallpaperFilter(site: "moewalls.com")) == ["city", "tall"])
        #expect(ids(WallpaperFilter(aspects: [.portrait, .wide])) == ["tall", "mine"])
        #expect(ids(WallpaperFilter(minimumResolution: .ultraHD)) == ["lake", "photo"])
        #expect(ids(WallpaperFilter(kind: .video, minimumResolution: .ultraHD)) == ["lake"])
        #expect(WallpaperFilter(site: "x").narrows)
    }

    @Test func everyWordHasToBeFoundSomewhere() {
        #expect(ids(WallpaperFilter(query: "moewalls")) == ["city", "tall"])
        #expect(ids(WallpaperFilter(query: "night moewalls")) == ["city"])
        #expect(ids(WallpaperFilter(query: "  LAKE  ")) == ["lake"])
        #expect(ids(WallpaperFilter(query: "nothing")) == [])
        #expect(WallpaperFilter(query: "a,b").words == ["a", "b"])
    }

    @Test func searchIgnoresCaseAndAccents() {
        #expect(ids(WallpaperFilter(query: "перес")) == ["tall"])
    }

    @Test func sitesMostUsedFirst() {
        #expect(WallpaperFilter.sites(in: items) == ["moewalls.com", "pexels.com", "wallhaven.cc"])
    }
}

@Suite struct PlaybackPolicyTests {
    let rules = PauseRules()

    func mode(_ situation: PlaybackSituation, _ rules: PauseRules = PauseRules()) -> PlaybackMode {
        PlaybackPolicy.mode(for: situation, rules: rules)
    }

    @Test func playsWhenSeenAndNothingElseSaysNo() {
        #expect(mode(PlaybackSituation()) == .play)
    }

    @Test func hiddenPausesOnItsFrameForAsLongAsItLasts() {
        #expect(mode(PlaybackSituation(isVisible: false)) == .pause(.hidden))
    }

    @Test func hiddenGoesOnPlayingWhenTheRuleIsOff() {
        #expect(mode(PlaybackSituation(isVisible: false), PauseRules(whenHidden: false)) == .play)
        // Sleep and the lock screen stop it all the same.
        #expect(
            mode(PlaybackSituation(isVisible: false, isScreenLocked: true), PauseRules(whenHidden: false))
                == .pause(.locked))
    }

    @Test func sleepLetsGoAndTheLockScreenKeepsTheFrame() {
        #expect(mode(.init(isSystemAsleep: true)) == .release(.asleep))
        #expect(mode(.init(isDisplayAsleep: true)) == .pause(.asleep))
        #expect(mode(.init(isScreenLocked: true)) == .pause(.locked))
    }

    @Test func powerRulesApplyOnlyWhenChosen() {
        let battery = PlaybackSituation(isOnBattery: true)
        #expect(mode(battery) == .play)
        #expect(mode(battery, PauseRules(onBattery: true)) == .pause(.battery))
        let lowPower = PlaybackSituation(isLowPowerMode: true)
        #expect(mode(lowPower) == .pause(.lowPower))
        #expect(mode(lowPower, PauseRules(inLowPowerMode: false)) == .play)
        let hot = PlaybackSituation(isHot: true)
        #expect(mode(hot) == .pause(.hot))
        #expect(mode(hot, PauseRules(whenHot: false)) == .play)
    }

    @Test func hiddenComesBeforePowerAsTheReason() {
        #expect(mode(PlaybackSituation(isVisible: false, isLowPowerMode: true)).reason == .hidden)
        // With the rule off, the power rules still apply.
        #expect(
            mode(PlaybackSituation(isVisible: false, isLowPowerMode: true), PauseRules(whenHidden: false))
                == .pause(.lowPower))
    }

    @Test func rulesSavedBeforeANewOneKeepTheirChoices() throws {
        let old = Data(#"{"onBattery":true,"inLowPowerMode":false,"whenHot":true}"#.utf8)
        let rules = try JSONDecoder().decode(PauseRules.self, from: old)
        #expect(rules == PauseRules(whenHidden: true, onBattery: true, inLowPowerMode: false, whenHot: true))
        let round = try JSONDecoder().decode(PauseRules.self, from: JSONEncoder().encode(PauseRules(whenHidden: false)))
        #expect(!round.whenHidden)
    }
}

@Suite struct DownloadLimitTests {
    let day: TimeInterval = 86_400
    let gigabyte: Int64 = 1_000_000_000

    func stored(
        _ id: String, gigabytes: Int64, daysAgo: Double, imported: Bool = false, inUse: Bool = false,
        favourite: Bool = false
    ) -> StoredWallpaper {
        StoredWallpaper(
            id: id, byteCount: gigabytes * gigabyte, lastUsed: Date(timeIntervalSince1970: 1e9 - daysAgo * day),
            isImported: imported, isInUse: inUse, isFavourite: favourite)
    }

    @Test func nothingGoesWithinTheLimitOrWithoutOne() {
        let items = [stored("a", gigabytes: 1, daysAgo: 1), stored("b", gigabytes: 1, daysAgo: 2)]
        #expect(DownloadLimit.toRemove(items, limit: 2 * gigabyte) == [])
        #expect(DownloadLimit.toRemove(items, limit: nil) == [])
    }

    @Test func theOldestGoFirstUntilItFits() {
        let items = [
            stored("new", gigabytes: 2, daysAgo: 1), stored("old", gigabytes: 2, daysAgo: 9),
            stored("middle", gigabytes: 2, daysAgo: 5),
        ]
        #expect(DownloadLimit.toRemove(items, limit: 3 * gigabyte) == ["old", "middle"])
        #expect(DownloadLimit.toRemove(items, limit: 5 * gigabyte) == ["old"])
    }

    @Test func ownFilesFavouritesAndWhatIsOnADisplayStay() {
        let items = [
            stored("own", gigabytes: 9, daysAgo: 30, imported: true),
            stored("shown", gigabytes: 3, daysAgo: 20, inUse: true),
            stored("liked", gigabytes: 2, daysAgo: 25, favourite: true), stored("spare", gigabytes: 1, daysAgo: 1),
        ]
        // Own files do not count, and what stays may leave downloads over the limit.
        #expect(DownloadLimit.usedBytes(items) == 6 * gigabyte)
        #expect(DownloadLimit.toRemove(items, limit: 1 * gigabyte) == ["spare"])
        #expect(DownloadLimit.clearable(items) == ["spare"])
    }
}

@Suite struct LibraryIndexTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func favouritesOnlyOfWhatIsThere() {
        var index = LibraryIndex()
        index.setFavourite("a", true)
        #expect(index.favourites.isEmpty)
        index.store(.init(wallpaper: wallpaper("a"), fileName: "a.mp4", added: now))
        index.setFavourite("a", true)
        index.setFavourite("a", true)
        #expect(index.favourites == ["a"])
        index.setFavourite("a", false)
        #expect(!index.isFavourite("a"))
    }

    @Test func removingReturnsItsFilesAndForgetsTheFavourite() {
        var index = LibraryIndex()
        index.store(.init(wallpaper: wallpaper("a"), fileName: "a.mp4", stillName: "a-still.jpg", added: now))
        index.store(.init(wallpaper: wallpaper("p", kind: .picture), fileName: "p.jpg", added: now))
        index.setFavourite("a", true)
        #expect(index.remove("a") == ["a.mp4", "a-still.jpg"])
        #expect(index.remove("p") == ["p.jpg"])
        #expect(index.remove("missing") == [])
        #expect(index.entries.isEmpty && index.favourites.isEmpty)
    }

    @Test func newestFirstAndRenamed() {
        var index = LibraryIndex()
        index.store(.init(wallpaper: wallpaper("old"), fileName: "old.mp4", added: now))
        index.store(.init(wallpaper: wallpaper("new"), fileName: "new.mp4", added: now.addingTimeInterval(5)))
        #expect(index.newestFirst.map(\.wallpaper.id) == ["new", "old"])
        index.rename("old", to: "  Beach  ")
        index.rename("new", to: "   ")
        #expect(index.entries["old"]?.wallpaper.title == "Beach")
        #expect(index.entries["new"]?.wallpaper.title == "Video")
    }

    @Test func describesItsFilesForTheLimit() {
        var index = LibraryIndex()
        index.store(.init(wallpaper: wallpaper("a"), fileName: "a.mp4", byteCount: 5, added: now))
        index.store(.init(wallpaper: wallpaper("m", origin: .imported), fileName: "m.mov", byteCount: 9, added: now))
        index.markUsed("a", at: now.addingTimeInterval(60))
        let items = index.stored(inUse: ["m"]).sorted { $0.id < $1.id }
        #expect(items.map(\.id) == ["a", "m"])
        #expect(items[0].lastUsed == now.addingTimeInterval(60))
        #expect(items[1].isImported && items[1].isInUse)
    }

    @Test func aChoiceCarriesWhatThePlayerNeeds() {
        var index = LibraryIndex()
        index.store(.init(wallpaper: wallpaper("a"), fileName: "a.mp4", stillName: "a-still.jpg", added: now))
        index.store(.init(wallpaper: wallpaper("p", kind: .picture), fileName: "p.jpg", added: now))
        let video = index.choice(for: "a", fit: .fit)
        #expect(video?.kind == .video && video?.fileName == "a.mp4" && video?.fit == .fit)
        #expect(video?.desktopPictureName == "a-still.jpg")
        #expect(index.choice(for: "p", fit: .fill)?.desktopPictureName == "p.jpg")
        #expect(index.entries["p"]?.desktopPictureName == "p.jpg")
        #expect(index.choice(for: "missing", fit: .fill) == nil)
    }

    @Test func optimizationIsRecordedOnce() throws {
        var index = LibraryIndex()
        index.store(
            .init(wallpaper: wallpaper("v", width: 3840, height: 2160), fileName: "v.mp4", byteCount: 100, added: now))
        index.store(.init(wallpaper: wallpaper("p", kind: .picture), fileName: "p.jpg", added: now))
        #expect(index.entries["v"]?.needsOptimization == true)
        #expect(index.entries["p"]?.needsOptimization == false)
        index.markOptimized("v", byteCount: 40, width: 3398, height: 1912)
        let entry = try #require(index.entries["v"])
        #expect(!entry.needsOptimization && entry.byteCount == 40 && entry.wallpaper.width == 3398)
        // A library saved before the mark existed reads as not optimized.
        let old = Data(
            #"{"version":1,"favourites":[],"entries":{"v":{"wallpaper":{"id":"v","kind":"video","origin":"downloaded","title":"V","width":1,"height":1,"duration":1},"fileName":"v.mp4","byteCount":1,"added":0,"lastUsed":0}}}"#
                .utf8)
        #expect(try JSONDecoder().decode(LibraryIndex.self, from: old).entries["v"]?.needsOptimization == true)
    }

    @Test func fileNamesAreSafe() {
        #expect(LibraryIndex.fileName(for: "downloaded-123", extension: "MP4") == "downloaded-123.mp4")
        #expect(LibraryIndex.fileName(for: "../../etc/x", extension: "mov") == "______etc_x.mov")
        #expect(LibraryIndex.fileName(for: "a", extension: "") == "a")
    }

    @Test func survivesARoundTrip() throws {
        var index = LibraryIndex()
        index.store(.init(wallpaper: wallpaper("a", site: "moewalls.com"), fileName: "a.mp4", added: now))
        index.setFavourite("a", true)
        let data = try JSONEncoder().encode(index)
        #expect(try JSONDecoder().decode(LibraryIndex.self, from: data) == index)
    }
}

@Suite struct DisplayAssignmentTests {
    let lake = WallpaperChoice(wallpaperID: "lake", fileName: "lake.mp4")
    let city = WallpaperChoice(wallpaperID: "city", fileName: "city.mp4")
    let photo = WallpaperChoice(wallpaperID: "photo", kind: .picture, fileName: "photo.jpg")

    @Test func oneForAllReachesNewDisplays() {
        var assignments = DisplayAssignments()
        assignments.set(lake, forDisplay: "A")
        #expect(assignments.choice(forDisplay: "A") == lake)
        #expect(assignments.choice(forDisplay: "new") == lake)
    }

    @Test func separateDisplaysKeepTheirOwn() {
        var assignments = DisplayAssignments()
        assignments.set(lake, forDisplay: "A")
        assignments.setSameOnAll(false, displays: ["A", "B"])
        // Nothing changes on screen at the moment of the switch.
        #expect(assignments.choice(forDisplay: "A") == lake)
        #expect(assignments.choice(forDisplay: "B") == lake)
        assignments.set(city, forDisplay: "B")
        #expect(assignments.choice(forDisplay: "A") == lake)
        #expect(assignments.choice(forDisplay: "B") == city)
        #expect(assignments.choice(forDisplay: "C") == nil)
        #expect(assignments.usedIDs == ["lake", "city"])
    }

    @Test func goingBackToOneForAllKeepsTheMainDisplays() {
        var assignments = DisplayAssignments(sameOnAll: false, perDisplay: ["A": city, "B": lake])
        assignments.setSameOnAll(true, displays: ["B", "A"])
        #expect(assignments.choice(forDisplay: "A") == lake)
    }

    @Test func removingAWallpaperClearsEveryDisplay() {
        var assignments = DisplayAssignments(sameOnAll: false, shared: lake, perDisplay: ["A": lake, "B": city])
        assignments.remove("lake")
        #expect(assignments.shared == nil)
        #expect(assignments.perDisplay == ["B": city])
        assignments.remove("city")
        #expect(assignments.isEmpty)
    }

    @Test func fitFollowsTheDisplay() {
        var assignments = DisplayAssignments(sameOnAll: false, perDisplay: ["A": lake, "B": city])
        assignments.setFit(.fit, forDisplay: "B")
        #expect(assignments.choice(forDisplay: "A")?.fit == .fill)
        #expect(assignments.choice(forDisplay: "B")?.fit == .fit)
    }

    @Test func thePlayerRunsOnlyForAVideoOnAConnectedDisplay() {
        #expect(!DisplayAssignments(shared: photo).hasVideo(forDisplays: ["A"]))
        #expect(DisplayAssignments(shared: lake).hasVideo(forDisplays: ["A"]))
        #expect(!DisplayAssignments(shared: lake).hasVideo(forDisplays: []))
        let separate = DisplayAssignments(sameOnAll: false, perDisplay: ["A": photo, "B": lake])
        #expect(!separate.hasVideo(forDisplays: ["A", "C"]))
        #expect(separate.hasVideo(forDisplays: ["A", "B"]))
    }
}

@Suite struct ImportCheckTests {
    let good = VideoFacts(
        hasVideo: true, isPlayable: true, codec: "hvc1", isHardwareDecoded: true, width: 3840, height: 2160,
        duration: 12)

    @Test func aGoodFilePasses() {
        #expect(ImportCheck.problem(with: good) == nil)
    }

    @Test func eachProblemIsNamed() {
        var facts = good
        facts.hasVideo = false
        #expect(ImportCheck.problem(with: facts) == .unsupported)
        facts = good
        facts.isProtected = true
        #expect(ImportCheck.problem(with: facts) == .protected)
        facts = good
        facts.isPlayable = false
        #expect(ImportCheck.problem(with: facts) == .unplayable)
        facts = good
        facts.isHardwareDecoded = false
        facts.codec = "av01"
        #expect(ImportCheck.problem(with: facts) == .needsSoftwareDecoding(codec: "av01"))
        facts = good
        facts.duration = 0.5
        #expect(ImportCheck.problem(with: facts) == .tooShort)
        facts = good
        facts.width = 15360
        #expect(ImportCheck.problem(with: facts) == .tooLarge)
    }

    @Test func pictures() {
        #expect(ImportCheck.problem(withPictureWidth: 3840, height: 2160) == nil)
        #expect(ImportCheck.problem(withPictureWidth: 300, height: 200) == .tooSmall)
        #expect(ImportCheck.problem(withPictureWidth: 0, height: 0) == .unsupported)
    }

    @Test func extensionsAndTitles() {
        #expect(ImportCheck.kind(ofExtension: "MOV") == .video)
        #expect(ImportCheck.kind(ofExtension: "m4v") == .video)
        #expect(ImportCheck.kind(ofExtension: "HEIC") == .picture)
        #expect(ImportCheck.kind(ofExtension: "webm") == nil)
        #expect(ImportCheck.title(fromFileName: "my_beach_trip.mov") == "my beach trip")
        #expect(ImportCheck.title(fromFileName: ".mov") == ".mov")
    }
}

@Suite struct BrowsingTests {
    @Test func theOwnersSites() {
        #expect(
            WallpaperSite.builtIn.map(\.name) == ["MoeWalls", "MotionBGs", "Pexels", "Pixabay", "Mixkit", "Wallhaven"])
        #expect(WallpaperSite.builtIn.allSatisfy { $0.address.scheme == "https" })
    }

    @Test func typedAddresses() {
        #expect(WallpaperSite.url(fromTyped: "moewalls.com")?.absoluteString == "https://moewalls.com")
        #expect(WallpaperSite.url(fromTyped: " http://a.b/c ")?.absoluteString == "http://a.b/c")
        #expect(WallpaperSite.url(fromTyped: "file:///etc/passwd") == nil)
        #expect(WallpaperSite.url(fromTyped: "javascript:alert(1)") == nil)
        #expect(WallpaperSite.url(fromTyped: "two words") == nil)
        #expect(WallpaperSite.url(fromTyped: "localhost") == nil)
    }

    @Test func whatBecomesADownload() {
        #expect(
            DownloadRule.shouldDownload(
                isMainFrame: true, mimeType: "text/html", contentDisposition: nil, canShow: false))
        #expect(
            DownloadRule.shouldDownload(
                isMainFrame: false, mimeType: "video/mp4", contentDisposition: "Attachment; filename=a.mp4",
                canShow: true))
        #expect(
            DownloadRule.shouldDownload(
                isMainFrame: true, mimeType: "video/mp4", contentDisposition: nil, canShow: true))
        #expect(
            DownloadRule.shouldDownload(
                isMainFrame: true, mimeType: "image/jpeg", contentDisposition: nil, canShow: true))
        // A page, and a video playing inside a page, stay as they are.
        #expect(
            !DownloadRule.shouldDownload(
                isMainFrame: true, mimeType: "text/html", contentDisposition: nil, canShow: true))
        #expect(
            !DownloadRule.shouldDownload(
                isMainFrame: false, mimeType: "video/mp4", contentDisposition: nil, canShow: true))
        #expect(
            !DownloadRule.shouldDownload(
                isMainFrame: true, mimeType: "text/html", contentDisposition: "inline", canShow: true))
    }

    @Test func whichDownloadsAreTaken() {
        #expect(DownloadRule.kind(mimeType: "video/mp4", fileName: "x") == .video)
        #expect(DownloadRule.kind(mimeType: "video/quicktime", fileName: "x.mov") == .video)
        #expect(DownloadRule.kind(mimeType: "image/png", fileName: "x") == .picture)
        #expect(DownloadRule.kind(mimeType: "application/octet-stream", fileName: "clip.MP4") == .video)
        #expect(DownloadRule.kind(mimeType: nil, fileName: "photo.jpeg") == .picture)
        #expect(DownloadRule.kind(mimeType: "video/webm", fileName: "clip.mp4") == nil)
        #expect(DownloadRule.kind(mimeType: "application/zip", fileName: "pack.zip") == nil)
        #expect(DownloadRule.kind(mimeType: "application/x-apple-diskimage", fileName: "Setup.dmg") == nil)
    }

    @Test func popUpsOpenInPlaceOnlyOnTheSameSite() throws {
        let page = try #require(URL(string: "https://moewalls.com/anime/frieren/"))
        let sameSite = try #require(URL(string: "https://cdn.moewalls.com/download.php?id=1"))
        let advert = try #require(URL(string: "https://ads.example.net/click"))
        let video = try #require(URL(string: "https://files.other.net/clip.mp4"))
        #expect(DownloadRule.opensInPlace(sameSite, from: page))
        #expect(!DownloadRule.opensInPlace(advert, from: page))
        #expect(DownloadRule.opensInPlace(video, from: page))
        #expect(!DownloadRule.opensInPlace(advert, from: nil))
    }

    @Test func thePopUnderTrickIsRefused() throws {
        let page = try #require(URL(string: "https://moewalls.com/anime/dark-goth-girl-live-wallpaper/"))
        let samePage = try #require(URL(string: "https://moewalls.com/anime/dark-goth-girl-live-wallpaper/#x"))
        let advert = try #require(URL(string: "https://onclickprediction.com/jump/next.php?r=1"))
        let download = try #require(URL(string: "https://go.moewalls.com/download.php?video=1"))
        #expect(DownloadRule.isPopUnder(samePage, on: page))
        #expect(!DownloadRule.isPopUnder(download, on: page))
        #expect(
            DownloadRule.blocksRedirect(
                to: advert, from: page, isMainFrame: true, isLinkClick: false, afterPopUnder: true))
        #expect(
            !DownloadRule.blocksRedirect(
                to: download, from: page, isMainFrame: true, isLinkClick: false, afterPopUnder: true))
        #expect(
            !DownloadRule.blocksRedirect(
                to: advert, from: page, isMainFrame: true, isLinkClick: true, afterPopUnder: true))
        #expect(
            !DownloadRule.blocksRedirect(
                to: advert, from: page, isMainFrame: true, isLinkClick: false, afterPopUnder: false))
        #expect(
            !DownloadRule.blocksRedirect(
                to: advert, from: page, isMainFrame: false, isLinkClick: false, afterPopUnder: true))
    }

    @Test func registrableDomains() throws {
        #expect(DownloadRule.registrableDomain(of: try #require(URL(string: "https://a.b.co.uk/x"))) == "b.co.uk")
        #expect(
            DownloadRule.registrableDomain(of: try #require(URL(string: "https://www.pexels.com/"))) == "pexels.com")
        #expect(DownloadRule.registrableDomain(of: try #require(URL(string: "https://wallhaven.cc"))) == "wallhaven.cc")
        #expect(
            DownloadRule.registrableDomain(of: try #require(URL(string: "http://127.0.0.1:8765/a.mp4"))) == "127.0.0.1")
        #expect(DownloadRule.registrableDomain(of: try #require(URL(string: "http://[::1]:80/a"))) == "::1")
    }

    @Test func namesFromThePageOrTheFile() {
        #expect(
            DownloadNaming.title(
                pageTitle: "Frieren And Fern Live Wallpaper - MoeWalls", fileName: "x.mp4", site: "moewalls.com")
                == "Frieren And Fern")
        #expect(
            DownloadNaming.title(
                pageTitle: "Ocean Waves | Free Stock Video - Pixabay", fileName: "x.mp4", site: "pixabay.com")
                == "Ocean Waves")
        #expect(
            DownloadNaming.title(
                pageTitle: "Wallhaven", fileName: "lofi-room-moewalls-com-3840x2160-24fps.mp4", site: "wallhaven.cc")
                == "Lofi room moewalls 3840x2160")
        #expect(
            DownloadNaming.title(pageTitle: nil, fileName: "rain_city_4k_2160p.mp4", site: "pexels.com") == "Rain city")
        #expect(DownloadNaming.title(pageTitle: "", fileName: "2160.mp4", site: nil) == "2160")
        #expect(DownloadNaming.site(of: URL(string: "https://www.Pexels.com/video/1")) == "pexels.com")
        #expect(DownloadNaming.site(of: URL(string: "https://go.moewalls.com/download.php")) == "moewalls.com")
        // Found on MoeWalls: the name of a download server must not take words that only start like it.
        #expect(
            DownloadNaming.title(
                pageTitle: "Dark Goth Girl Live Wallpaper - MoeWalls", fileName: "dark-goth-girl-moewalls-com.mp4",
                site: "moewalls.com") == "Dark Goth Girl")
        #expect(
            DownloadNaming.title(pageTitle: "Pixabay.com", fileName: "ocean_waves.mp4", site: "pixabay.com")
                == "Ocean waves")
    }
}

@Suite struct DesktopPictureMemoryTests {
    let aerial = DesktopPictureMemory.Original(path: "/System/Library/CoreServices/DefaultDesktop.heic")
    let photo = DesktopPictureMemory.Original(path: "/Users/me/Pictures/sea.jpg", options: ["allowClipping": 1])
    let ours = DesktopPictureMemory.Original(path: "/Users/me/Library/Application Support/x/Wallpapers/a.jpg")

    @Test func remembersOnlyTheFirstPictureThatIsNotOurs() {
        var memory = DesktopPictureMemory()
        memory.remember(display: "A", current: ours, isOurs: true)
        #expect(memory.originals.isEmpty)
        memory.remember(display: "A", current: photo, isOurs: false)
        memory.remember(display: "A", current: aerial, isOurs: false)
        #expect(memory.originals["A"] == photo)
    }

    @Test func givesBackOnlyWhatThePersonDidNotReplace() {
        var memory = DesktopPictureMemory(originals: ["A": photo, "B": photo])
        #expect(memory.takeBack(display: "A", currentIsOurs: true) == photo)
        #expect(memory.takeBack(display: "B", currentIsOurs: false) == nil)
        #expect(memory.originals.isEmpty)
        #expect(memory.takeBack(display: "A", currentIsOurs: true) == nil)
    }

    @Test func recognisesTheSystemDefault() {
        #expect(DesktopPictureMemory.isSystemDefault(aerial.path))
        #expect(!DesktopPictureMemory.isSystemDefault(photo.path))
    }
}

@Suite struct VideoOptimizationTests {
    @Test func aVideoThatWouldPlayNoLighterStaysAsItCame() {
        let air = (width: 2940, height: 1912)
        // An odd size loses a line to the encoder, a stated rate strays from 60, and avc3 is H.264.
        #expect(
            VideoOptimization.plan(
                for: VideoSource(codec: "avc1", width: 1279, height: 721, framesPerSecond: 30), displays: [air]) == nil)
        #expect(
            VideoOptimization.plan(
                for: VideoSource(codec: "hvc1", width: 1920, height: 1080, framesPerSecond: 60.02), displays: [air])
                == nil)
        #expect(
            VideoOptimization.plan(
                for: VideoSource(codec: "avc3", width: 1920, height: 1080, framesPerSecond: 30), displays: [air]) == nil
        )
    }

    let macBookAir = (width: 2940, height: 1912)
    let display4K = (width: 3840, height: 2160)

    @Test func anH264OrHEVCVideoUpTo4KAnd60FramesStaysAsItCame() {
        // The decoder costs the same for either codec at the same size and rate, and re-encoding loses a little.
        let heavy = VideoSource(codec: "avc1", width: 3840, height: 2160, framesPerSecond: 60)
        #expect(VideoOptimization.plan(for: heavy, displays: [macBookAir]) == nil)
        let hevc = VideoSource(codec: "hvc1", width: 1920, height: 1080, framesPerSecond: 30)
        #expect(VideoOptimization.plan(for: hevc, displays: [display4K]) == nil)
        let tall = VideoSource(codec: "avc1", width: 1080, height: 1920, framesPerSecond: 30)
        #expect(VideoOptimization.plan(for: tall, displays: [display4K]) == nil)
    }

    @Test func onlyLargerThan4KIsShrunkAndTheLargestDisplayDecidesHowFar() throws {
        let source = VideoSource(codec: "hvc1", width: 7680, height: 4320, framesPerSecond: 30)
        let onAir = try #require(VideoOptimization.plan(for: source, displays: [macBookAir]))
        #expect(onAir.width == 3840 && onAir.height == 2160)
        #expect(onAir.quality == VideoOptimization.quality)
        let on5K = try #require(VideoOptimization.plan(for: source, displays: [macBookAir, (5120, 2880)]))
        #expect(on5K.width == 5120 && on5K.height == 2880)
        let unknown = try #require(VideoOptimization.plan(for: source, displays: []))
        #expect(unknown.width == 3840)
    }

    @Test func tooManyFramesOrAnotherCodecAreConverted() throws {
        let fast = VideoSource(codec: "hvc1", width: 1920, height: 1080, framesPerSecond: 120)
        let plan = try #require(VideoOptimization.plan(for: fast, displays: [macBookAir]))
        #expect(plan.framesPerSecond == 60 && plan.width == 1920)
        let proRes = VideoSource(codec: "apcn", width: 1920, height: 1080, framesPerSecond: 30)
        #expect(VideoOptimization.plan(for: proRes, displays: [macBookAir]) != nil)
    }

    @Test func nothingToPlanWithoutASize() {
        #expect(
            VideoOptimization.plan(
                for: VideoSource(codec: "avc1", width: 0, height: 0, framesPerSecond: 30),
                displays: []) == nil)
    }
}

@Suite struct EconomyModeTests {
    @Test func everySecondOrLaterFrameIsKeptSoTheMotionStaysEven() {
        #expect(EconomyMode.frameRate(for: 60) == 30)
        #expect(EconomyMode.frameRate(for: 50) == 25)
        #expect(EconomyMode.frameRate(for: 120) == 30)
        #expect(EconomyMode.frameRate(for: 48) == 24)
        let ntsc = EconomyMode.frameRate(for: 59.94) ?? 0
        #expect(abs(ntsc - 29.97) < 0.01)
    }

    @Test func aSlowVideoOrOneThatWouldStutterHasNoCopy() {
        #expect(EconomyMode.frameRate(for: 30) == nil)
        #expect(EconomyMode.frameRate(for: 24) == nil)
        // From 40 to 30 frames a second, one frame in four would go, and the motion would jerk.
        #expect(EconomyMode.frameRate(for: 40) == nil)
        #expect(EconomyMode.frameRate(for: 0) == nil)
    }

    @Test func theCopySitsNextToTheVideo() {
        #expect(WallpaperVariant.name(for: "downloaded-A.mp4", size: nil, economy: true) == "downloaded-A-economy.mp4")
        #expect(WallpaperVariant.name(for: "imported-B.mov", size: nil, economy: true) == "imported-B-economy.mov")
    }
}

@Suite struct PlaybackSizeTests {
    let fourK = PixelSize(width: 3840, height: 2160)
    /// A MacBook Air M2's own panel, which the system draws at 2940×1912 and shrinks.
    let air = PixelSize(width: 2560, height: 1664)

    @Test func onADisplayItCoversThePanelAndNoMore() {
        #expect(WallpaperSizing.size(of: fourK, setting: .display, panel: air) == PixelSize(width: 2958, height: 1664))
        // A 4K display needs all of a 4K video, and a smaller video never grows.
        #expect(WallpaperSizing.size(of: fourK, setting: .display, panel: fourK) == nil)
        let fullHD = PixelSize(width: 1920, height: 1080)
        #expect(WallpaperSizing.size(of: fullHD, setting: .display, panel: air) == nil)
        // A tall picture covers the width of a wide display.
        let tall = PixelSize(width: 4000, height: 6000)
        #expect(WallpaperSizing.size(of: tall, setting: .display, panel: air) == PixelSize(width: 2560, height: 3840))
        #expect(WallpaperSizing.size(of: fourK, setting: .display, panel: nil) == nil)
    }

    @Test func aPresetHoldsTheShortSide() {
        #expect(WallpaperSizing.size(of: fourK, setting: .fullHD, panel: air) == PixelSize(width: 1920, height: 1080))
        #expect(WallpaperSizing.size(of: fourK, setting: .quadHD, panel: nil) == PixelSize(width: 2560, height: 1440))
        #expect(WallpaperSizing.size(of: fourK, setting: .ultraHD, panel: nil) == nil)
        let wide = PixelSize(width: 5120, height: 1440)
        #expect(WallpaperSizing.size(of: wide, setting: .fullHD, panel: nil) == PixelSize(width: 3840, height: 1080))
        #expect(WallpaperSizing.size(of: fourK, setting: .original, panel: air) == nil)
    }

    @Test func aCopyThatSavesLittleIsNotMade() {
        // 3840×2160 on a 3600×2025 display would keep 88 % of the pixels.
        #expect(WallpaperSizing.size(of: fourK, setting: .display, panel: PixelSize(width: 3600, height: 2025)) == nil)
        #expect(WallpaperSizing.size(of: fourK, setting: .display, panel: PixelSize(width: 3400, height: 1912)) != nil)
    }

    @Test func copiesAreNamedBySizeAndFrames() {
        let size = PixelSize(width: 2958, height: 1664)
        #expect(WallpaperVariant.name(for: "a.mp4", size: size, economy: false) == "a-2958x1664.mp4")
        #expect(WallpaperVariant.name(for: "a.mp4", size: size, economy: true) == "a-2958x1664-economy.mp4")
        #expect(WallpaperVariant.name(for: "a.mp4", size: nil, economy: true) == "a-economy.mp4")
        #expect(WallpaperVariant.name(for: "a.mp4", size: nil, economy: false) == "a.mp4")
    }

    @Test func aDisplayPlaysTheClosestCopyThatExists() {
        let size = PixelSize(width: 2958, height: 1664)
        let all: Set = ["a-2958x1664-economy.mp4", "a-2958x1664.mp4", "a-economy.mp4"]
        func play(_ present: Set<String>, size: PixelSize?, economy: Bool) -> String {
            WallpaperVariant.fileToPlay("a.mp4", size: size, economy: economy, exists: present.contains)
        }
        #expect(play(all, size: size, economy: true) == "a-2958x1664-economy.mp4")
        #expect(play(all, size: size, economy: false) == "a-2958x1664.mp4")
        #expect(play(all, size: nil, economy: true) == "a-economy.mp4")
        // Until the smaller copy with fewer frames is made, the smaller one plays, then the slower one.
        #expect(play(["a-2958x1664.mp4", "a-economy.mp4"], size: size, economy: true) == "a-2958x1664.mp4")
        #expect(play(["a-economy.mp4"], size: size, economy: true) == "a-economy.mp4")
        #expect(play([], size: size, economy: true) == "a.mp4")
    }

    @Test func twoDisplaysOfDifferentSizesNeedACopyEach() {
        let external = PixelSize(width: 1920, height: 1080)
        let needed = WallpaperVariant.needed(
            source: fourK, kind: .video, setting: .display, panels: [air, external, air], economy: false)
        #expect(
            needed == [
                .init(size: PixelSize(width: 2958, height: 1664), economy: false),
                .init(size: PixelSize(width: 1920, height: 1080), economy: false),
            ])
        // A 4K display keeps the video as it is, unless economy mode wants fewer frames.
        #expect(
            WallpaperVariant.needed(source: fourK, kind: .video, setting: .display, panels: [fourK], economy: false)
                .isEmpty)
        #expect(
            WallpaperVariant.needed(source: fourK, kind: .video, setting: .display, panels: [fourK], economy: true)
                == [.init(size: nil, economy: true)])
        // A picture has no frames to leave out.
        #expect(
            WallpaperVariant.needed(source: fourK, kind: .picture, setting: .display, panels: [air], economy: true)
                == [.init(size: PixelSize(width: 2958, height: 1664), economy: false)])
    }

    @Test func copiesAreRecordedAndGoWithTheirWallpaper() {
        let wallpaper = Wallpaper(
            id: "a", kind: .video, origin: .downloaded, title: "A", width: 3840, height: 2160, duration: 20)
        var index = LibraryIndex()
        var entry = LibraryIndex.Entry(wallpaper: wallpaper, fileName: "a.mp4", stillName: "a-still.jpg", added: .now)
        entry.economyName = "a-economy.mp4"
        index.store(entry)
        index.markVariant("a", name: "a-2958x1664.mp4", byteCount: 150)
        index.markVariant("a", name: "a-2958x1664.mp4", byteCount: 160)
        index.markVariant("a", name: "a-still-2958x1664.jpg", byteCount: 170)
        #expect(index.entries["a"]?.variants == ["a-2958x1664.mp4", "a-still-2958x1664.jpg"])
        #expect(index.entries["a"]?.byteCount == 170)
        #expect(
            Set(index.remove("a"))
                == ["a.mp4", "a-still.jpg", "a-economy.mp4", "a-2958x1664.mp4", "a-still-2958x1664.jpg"])
    }
}

@Suite struct MediaSafetyTests {
    private func header(_ bytes: [UInt8], _ text: String = "", at offset: Int = 0) -> [UInt8] {
        var result = bytes
        if !text.isEmpty {
            if result.count < offset { result += [UInt8](repeating: 0, count: offset - result.count) }
            result += Array(text.utf8)
        }
        return result + [UInt8](repeating: 0, count: max(0, SniffedMedia.headerLength - result.count))
    }

    @Test func picturesAreToldByTheirBytes() {
        #expect(SniffedMedia.sniff(header([0xFF, 0xD8, 0xFF, 0xE0]))?.format == .jpeg)
        #expect(SniffedMedia.sniff(header([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))?.format == .png)
        #expect(SniffedMedia.sniff(header([], "GIF89a")) == SniffedMedia(kind: .picture, format: .gif))
        #expect(SniffedMedia.sniff(header(Array("RIFF".utf8) + [1, 2, 3, 4], "WEBP", at: 8))?.format == .webp)
        #expect(SniffedMedia.sniff(header([0, 0, 0, 24], "ftypheic", at: 4))?.format == .heif)
        #expect(SniffedMedia.sniff(header([0, 0, 0, 24], "ftypavif", at: 4))?.format == .avif)
    }

    @Test func videosAreToldByTheirBytesAndAHEICIsNotOne() {
        #expect(
            SniffedMedia.sniff(header([0, 0, 0, 32], "ftypisom", at: 4)) == SniffedMedia(kind: .video, format: .mpeg4))
        #expect(SniffedMedia.sniff(header([0, 0, 0, 32], "ftypqt  ", at: 4))?.format == .quickTime)
        #expect(SniffedMedia.sniff(header([0, 0, 0, 8], "moov", at: 4))?.format == .quickTime)
        #expect(SniffedMedia.sniff(header([0, 0, 0, 24], "ftypmif1", at: 4))?.kind == .picture)
    }

    @Test func whatOnlyCallsItselfAPictureOrVideoIsRefusedUnread() {
        // A PDF named .gif, as in FORCEDENTRY.
        #expect(SniffedMedia.sniff(header([], "%PDF-1.7")) == nil)
        // A Mach-O program, a script, a zip, a web page, a TIFF, a BMP.
        #expect(SniffedMedia.sniff(header([0xCF, 0xFA, 0xED, 0xFE])) == nil)
        #expect(SniffedMedia.sniff(header([], "#!/bin/sh")) == nil)
        #expect(SniffedMedia.sniff(header([0x50, 0x4B, 0x03, 0x04])) == nil)
        #expect(SniffedMedia.sniff(header([], "<!DOCTYPE html>")) == nil)
        #expect(SniffedMedia.sniff(header([0x49, 0x49, 0x2A, 0x00])) == nil)
        #expect(SniffedMedia.sniff(header([], "BM")) == nil)
        #expect(SniffedMedia.sniff([]) == nil)
    }

    @Test func aJobStaysInsideTheInbox() {
        let inbox = "/Users/me/Library/Caches/Tweakly Media Inbox"
        #expect(MediaInbox.isJobFolder(inbox + "/1A2B", inbox: inbox))
        #expect(!MediaInbox.isJobFolder(inbox + "/../Secrets", inbox: inbox))
        #expect(!MediaInbox.isJobFolder(inbox + "/a/b", inbox: inbox))
        #expect(!MediaInbox.isJobFolder(inbox, inbox: inbox))
        #expect(!MediaInbox.isJobFolder("/tmp/1A2B", inbox: inbox))
        #expect(MediaInbox.isPlainName("clean.png"))
        for name in ["", ".", "..", "../x", "a/b", ".hidden", "a\0b"] { #expect(!MediaInbox.isPlainName(name)) }
    }

    @Test func aReplyCrossesAsPlainData() throws {
        let cleaned = CleanedMedia(
            kind: .video, fileName: "clean.mp4", stillName: "still.jpg", thumbnailName: "thumbnail.jpg", width: 3840,
            height: 2160, duration: 20.9)
        for reply in [
            CleanReply.cleaned(cleaned), .refused(.needsSoftwareDecoding(codec: "vp09")), .refused(.couldNotCheck),
        ] {
            let data = try JSONEncoder().encode(reply)
            #expect(try JSONDecoder().decode(CleanReply.self, from: data) == reply)
        }
        var escaping = cleaned
        escaping.stillName = "../../evil.jpg"
        #expect(cleaned.namesArePlain && !escaping.namesArePlain)
    }

    @Test func anEnormousPictureIsRefusedBeforeItIsDecoded() {
        #expect(ImportCheck.problem(withPictureWidth: 60_000, height: 60_000) == .tooLarge)
        #expect(ImportCheck.problem(withPictureWidth: 3840, height: 2160) == nil)
    }

    @Test func cleanedFilesReplaceTheOldOnEveryDisplay() {
        var assignments = DisplayAssignments(
            sameOnAll: false, shared: nil,
            perDisplay: [
                "a": WallpaperChoice(wallpaperID: "p", kind: .picture, fileName: "p.jpg", fit: .fit),
                "b": WallpaperChoice(wallpaperID: "q", kind: .picture, fileName: "q.jpg"),
            ])
        assignments.renameFiles(of: "p", fileName: "p.png", stillName: nil)
        #expect(assignments.perDisplay["a"]?.fileName == "p.png" && assignments.perDisplay["a"]?.fit == .fit)
        #expect(assignments.perDisplay["b"]?.fileName == "q.jpg")
    }
}

/// Stores shaped as WallpaperAgent's own on macOS 27.2: an Aerial chosen in System Settings, then Tweakly's stills.
@Suite struct WallpaperStoreTests {
    static let ourFolder = "/Users/me/Library/Application Support/me.tweakly.Tweakly/Wallpapers/"
    let still = ourFolder + "downloaded-A-still.jpg"
    let display = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

    func isOurs(_ path: String) -> Bool { path.hasPrefix(Self.ourFolder) }

    func image(_ path: String) -> [String: Any] {
        let configuration = try! PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile", "url": ["relative": URL(fileURLWithPath: path).absoluteString]],
            format: .binary, options: 0)
        return choice("com.apple.wallpaper.choice.image", configuration)
    }

    func aerial(_ id: String) -> [String: Any] {
        let configuration = try! PropertyListSerialization.data(
            fromPropertyList: ["assetID": id], format: .binary, options: 0)
        return choice("com.apple.wallpaper.choice.aerials", configuration)
    }

    func choice(_ provider: String, _ configuration: Data) -> [String: Any] {
        [
            "Content": [
                "Choices": [["Provider": provider, "Configuration": configuration, "Files": [Any]()]],
                "Shuffle": "$null",
            ],
            "LastSet": Date(timeIntervalSince1970: 1),
        ]
    }

    func place(_ desktop: [String: Any]?) -> [String: Any] {
        var place: [String: Any] = ["Type": "individual", "Idle": aerial("SAVER")]
        if let desktop { place["Desktop"] = desktop }
        return place
    }

    /// A store with one display, the main Space and more Spaces by ID, each showing `desktop` unless given its own.
    func store(_ desktop: [String: Any], spaces: [String: [String: Any]?] = [:], everywhere: Any = "$null")
        -> [String: Any]
    {
        var allSpaces: [String: Any] = ["": ["Default": place(desktop), "Displays": [display: place(desktop)]]]
        for (id, own) in spaces {
            allSpaces[id] = ["Default": place(own), "Displays": [display: place(own)]]
        }
        return [
            "SystemDefault": place(desktop), "AllSpacesAndDisplays": everywhere,
            "Displays": [display: place(desktop)], "Spaces": allSpaces,
        ]
    }

    func assetID(_ store: [String: Any], _ place: WallpaperStore.Location) -> String? {
        guard let entry = WallpaperStore.value(at: place, in: store) as? [String: Any],
            let desktop = entry["Desktop"] as? [String: Any], let content = desktop["Content"] as? [String: Any],
            let choices = content["Choices"] as? [[String: Any]], let data = choices.first?["Configuration"] as? Data,
            let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return configuration["assetID"] as? String
    }

    func restored(_ current: [String: Any], from snapshot: [String: Any]) -> [String: Any]? {
        if case .changed(let store) = WallpaperStore.restored(current, from: snapshot, isOurs: isOurs) { return store }
        return nil
    }

    @Test func anAerialComesBackEverywhereOursWas() {
        let snapshot = store(aerial("GOLDEN-GATE"))
        let result = restored(store(image(still)), from: snapshot)
        for place: WallpaperStore.Location in [
            ["SystemDefault"], ["Displays", display], ["Spaces", "", "Default"], ["Spaces", "", "Displays", display],
        ] {
            #expect(assetID(result ?? [:], place) == "GOLDEN-GATE")
        }
        let idle = (WallpaperStore.value(at: ["Displays", display], in: result ?? [:]) as? [String: Any])?["Idle"]
        #expect((idle as? NSDictionary)?.isEqual(to: aerial("SAVER")) == true)
    }

    @Test func whatThePersonChoseMeanwhileStays() {
        let mine = "/Users/me/Pictures/sea.jpg"
        let snapshot = store(aerial("GOLDEN-GATE"), spaces: ["S2": aerial("GOLDEN-GATE")])
        let current = store(image(still), spaces: ["S2": image(mine)])
        let result = restored(current, from: snapshot) ?? [:]
        let entry = WallpaperStore.value(at: ["Spaces", "S2", "Displays", display], in: result) as? [String: Any]
        #expect(WallpaperStore.picturePaths(of: entry?["Desktop"] as? [String: Any] ?? [:]) == [mine])
        #expect(assetID(result, ["Spaces", "", "Displays", display]) == "GOLDEN-GATE")
    }

    @Test func aSpaceThatCameLaterFallsBackToTheDefault() {
        let result = restored(store(image(still), spaces: ["NEW": image(still)]), from: store(aerial("GOLDEN-GATE")))
        let entry =
            WallpaperStore.value(at: ["Spaces", "NEW", "Displays", display], in: result ?? [:])
            as? [String: Any]
        #expect(entry?["Desktop"] == nil)
        #expect(entry?["Idle"] != nil && entry?["Type"] as? String == "individual")
    }

    @Test func aStillLeftByAnOlderVersionGetsTheDisplaysChoice() {
        let snapshot = store(aerial("GOLDEN-GATE"), spaces: ["OLD": image(still)])
        let result = restored(store(image(still), spaces: ["OLD": image(still)]), from: snapshot) ?? [:]
        #expect(assetID(result, ["Spaces", "OLD", "Displays", display]) == "GOLDEN-GATE")
        #expect(assetID(result, ["Spaces", "OLD", "Default"]) == "GOLDEN-GATE")
    }

    @Test func allSpacesAndDisplaysGoesBackToNothing() {
        let result = restored(store(image(still), everywhere: place(image(still))), from: store(aerial("A")))
        #expect(result?["AllSpacesAndDisplays"] as? String == "$null")
    }

    @Test func nothingOfOursChangesNothing() {
        let current = store(aerial("GOLDEN-GATE"))
        guard case .unchanged = WallpaperStore.restored(current, from: current, isOurs: isOurs) else {
            Issue.record("expected no change")
            return
        }
    }

    @Test func anUnknownShapeIsLeftAlone() {
        var current = store(image(still))
        current.removeValue(forKey: "Spaces")
        guard case .unknownShape = WallpaperStore.restored(current, from: store(aerial("A")), isOurs: isOurs) else {
            Issue.record("expected unknown shape")
            return
        }
    }

    @Test func onlyPicturesOfOursCount() {
        #expect(WallpaperStore.showsOurs(image(still), isOurs: isOurs))
        #expect(!WallpaperStore.showsOurs(image("/Users/me/Pictures/sea.jpg"), isOurs: isOurs))
        #expect(!WallpaperStore.showsOurs(aerial("A"), isOurs: isOurs))
        var mixed = image(still)
        var content = mixed["Content"] as? [String: Any] ?? [:]
        content["Choices"] =
            ((content["Choices"] as? [Any]) ?? [])
            + ((aerial("A")["Content"] as? [String: Any])?["Choices"] as? [Any] ?? [])
        mixed["Content"] = content
        #expect(WallpaperStore.picturePaths(of: mixed) == nil)
    }
}

@Suite struct CodecNameTests {
    @Test func fourLettersReadAsCoreMediaWritesThem() {
        #expect(VideoFacts.codecName(0x6176_6331) == "avc1")
        #expect(VideoFacts.codecName(0x6876_6331) == "hvc1")
        // A shorter code is padded with spaces, which say nothing.
        #expect(VideoFacts.codecName(0x7261_7720) == "raw")
    }
}

@Suite struct CleanerOutputTests {
    private let manager = FileManager.default

    /// A job folder as the client makes it, with the cleaner's file in it, and the folder the library takes into.
    private func setUp() throws -> (root: String, job: String, made: CleanerOutput.Identity, into: String) {
        let root = manager.temporaryDirectory.appending(path: "cleaner-output-\(UUID().uuidString)").path
        let job = root + "/inbox/job"
        let into = root + "/incoming"
        try manager.createDirectory(atPath: job, withIntermediateDirectories: true)
        try manager.createDirectory(atPath: into, withIntermediateDirectories: true)
        let made = try CleanerOutput.Identity(of: job)
        try Data("video".utf8).write(to: URL(fileURLWithPath: job + "/v.mp4"))
        return (root, job, made, into)
    }

    @Test func theCleanersOwnFilesAreTaken() throws {
        let (root, job, made, into) = try setUp()
        defer { try? manager.removeItem(atPath: root) }
        try CleanerOutput.take(["v.mp4"], from: job, madeAs: made, into: into)
        #expect(try String(contentsOfFile: into + "/v.mp4", encoding: .utf8) == "video")
        #expect(!manager.fileExists(atPath: job + "/v.mp4"))
        let mode = try manager.attributesOfItem(atPath: into + "/v.mp4")[.posixPermissions] as? Int
        #expect(mode == 0o644)
    }

    @Test func aJobFolderSwappedForALinkGivesNothing() throws {
        let (root, job, made, into) = try setUp()
        defer { try? manager.removeItem(atPath: root) }
        // Someone's own file, which the cleaner may not read, reached through a link where its folder was.
        try manager.createDirectory(atPath: root + "/Documents", withIntermediateDirectories: true)
        try Data("taxes".utf8).write(to: URL(fileURLWithPath: root + "/Documents/v.mp4"))
        try manager.moveItem(atPath: job, toPath: root + "/inbox/moved")
        try manager.createSymbolicLink(atPath: job, withDestinationPath: root + "/Documents")
        #expect(throws: CleanerOutput.Refused.self) {
            try CleanerOutput.take(["v.mp4"], from: job, madeAs: made, into: into)
        }
        #expect(try String(contentsOfFile: root + "/Documents/v.mp4", encoding: .utf8) == "taxes")
        #expect(try manager.contentsOfDirectory(atPath: into).isEmpty)
    }

    @Test func anotherRealFolderInThePlaceOfTheJobsGivesNothing() throws {
        let (root, job, made, into) = try setUp()
        defer { try? manager.removeItem(atPath: root) }
        try manager.moveItem(atPath: job, toPath: root + "/inbox/moved")
        try manager.createDirectory(atPath: job, withIntermediateDirectories: true)
        try Data("other".utf8).write(to: URL(fileURLWithPath: job + "/v.mp4"))
        #expect(throws: CleanerOutput.Refused.self) {
            try CleanerOutput.take(["v.mp4"], from: job, madeAs: made, into: into)
        }
    }

    @Test func aLinkInsteadOfAFileGivesNothing() throws {
        let (root, job, made, into) = try setUp()
        defer { try? manager.removeItem(atPath: root) }
        try Data("taxes".utf8).write(to: URL(fileURLWithPath: root + "/secret"))
        try manager.removeItem(atPath: job + "/v.mp4")
        try manager.createSymbolicLink(atPath: job + "/v.mp4", withDestinationPath: root + "/secret")
        #expect(throws: CleanerOutput.Refused.self) {
            try CleanerOutput.take(["v.mp4"], from: job, madeAs: made, into: into)
        }
        #expect(try String(contentsOfFile: root + "/secret", encoding: .utf8) == "taxes")
        #expect(try manager.contentsOfDirectory(atPath: into).isEmpty)
    }

    @Test func aHardLinkToAnotherFileGivesNothing() throws {
        let (root, job, made, into) = try setUp()
        defer { try? manager.removeItem(atPath: root) }
        try Data("taxes".utf8).write(to: URL(fileURLWithPath: root + "/secret"))
        try manager.removeItem(atPath: job + "/v.mp4")
        try manager.linkItem(atPath: root + "/secret", toPath: job + "/v.mp4")
        #expect(throws: CleanerOutput.Refused.self) {
            try CleanerOutput.take(["v.mp4"], from: job, madeAs: made, into: into)
        }
        #expect(manager.fileExists(atPath: root + "/secret"))
    }

    @Test func aNameThatClimbsOutGivesNothing() throws {
        let (root, job, made, into) = try setUp()
        defer { try? manager.removeItem(atPath: root) }
        #expect(throws: CleanerOutput.Refused.self) {
            try CleanerOutput.take(["../v.mp4"], from: job, madeAs: made, into: into)
        }
    }
}
