import AppKit
import LiveWallpaperCore
import os

/// The system's own desktop picture of each display, which shows a picture from the library, or the first frame of a
/// video under its window. That way the menu bar picks its text colour from what is really on the desktop, Mission
/// Control and the lock screen match, and a paused video needs nothing held to look right.
///
/// Before the first change the system's whole wallpaper store is copied, and when the tweak goes off every desktop
/// entry still showing a picture of ours gets back what it held, an Aerial and every Space included
/// (`SystemWallpaperStore`). The picture each display showed is also noted, for the
/// public way to put back if the store cannot be used: that way an Aerial comes back as the system's default picture,
/// and only on the Space in front.
enum DesktopPicture {
    private static let memoryKey = "liveWallpaperDesktopMemory"
    /// Set when a display got the system's default picture back, which may stand for an Aerial, for the page to say.
    static let restoredDefaultKey = "liveWallpaperRestoredDefault"
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "live-wallpaper")

    /// Puts a display's wallpaper on its desktop, or gives the display its own picture back if it has none. With a
    /// size, the copy of the picture or the video's still made for it goes there once it exists.
    static func show(_ choice: WallpaperChoice?, on screen: NSScreen, size: PixelSize? = nil) {
        guard let key = WallpaperFolder.key(of: screen) else { return }
        guard let choice, let name = pictureName(of: choice, size: size), let url = WallpaperFolder.file(named: name),
            FileManager.default.fileExists(atPath: url.path)
        else {
            restore(display: key, on: screen)
            return
        }
        let workspace = NSWorkspace.shared
        let options = Self.options(for: choice.fit)
        let current = workspace.desktopImageURL(for: screen)
        if current?.standardizedFileURL == url.standardizedFileURL,
            sameOptions(workspace.desktopImageOptions(for: screen), options)
        {
            return
        }
        var memory = readMemory()
        memory.remember(
            display: key, current: current.map { original($0, workspace.desktopImageOptions(for: screen)) },
            isOurs: isOurs(current))
        writeMemory(memory)
        SystemWallpaperStore.takeSnapshotIfNeeded()
        do {
            try workspace.setDesktopImageURL(url, for: screen, options: options)
        } catch {
            log.error("Could not set the desktop picture: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func pictureName(of choice: WallpaperChoice, size: PixelSize?) -> String? {
        guard let name = choice.desktopPictureName else { return nil }
        let copy = WallpaperVariant.name(for: name, size: size, economy: false)
        guard copy != name, let url = WallpaperFolder.file(named: copy),
            FileManager.default.fileExists(atPath: url.path)
        else { return name }
        return copy
    }

    /// Gives one display its own picture back.
    static func restore(display key: String, on screen: NSScreen) {
        var memory = readMemory()
        guard memory.originals[key] != nil else { return }
        let current = NSWorkspace.shared.desktopImageURL(for: screen)
        let original = memory.takeBack(display: key, currentIsOurs: isOurs(current))
        writeMemory(memory)
        guard let original else { return }
        let url = URL(fileURLWithPath: original.path)
        do {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options(from: original.options))
            if DesktopPictureMemory.isSystemDefault(original.path) {
                UserDefaults.standard.set(true, forKey: restoredDefaultKey)
            }
        } catch {
            log.error("Could not give the desktop picture back: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every display gets its own choice back from the store. Without it, every connected display gets its noted
    /// picture back, and a display that is not connected keeps its note for the next time the agent starts with the
    /// tweak off.
    static func restoreAll(on screens: [NSScreen]) {
        if SystemWallpaperStore.hasSnapshot, SystemWallpaperStore.restore() {
            // The store held every display's own choice, connected or not.
            writeMemory(DesktopPictureMemory())
            return
        }
        for screen in screens {
            if let key = WallpaperFolder.key(of: screen) { restore(display: key, on: screen) }
        }
    }

    static var hasRemembered: Bool { !readMemory().originals.isEmpty || SystemWallpaperStore.hasSnapshot }

    private static func isOurs(_ url: URL?) -> Bool {
        guard let path = url?.standardizedFileURL.path, let folder = WallpaperFolder.files?.standardizedFileURL.path
        else { return false }
        return path.hasPrefix(folder + "/")
    }

    /// As System Settings sets them: Fill Screen, Fit to Screen on black, and Stretch to Fill Screen.
    private static func options(for fit: VideoFit) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        switch fit {
        case .fill:
            [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
        case .fit:
            [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: false,
                .fillColor: NSColor.black,
            ]
        case .stretch:
            [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true]
        }
    }

    private static func sameOptions(
        _ lhs: [NSWorkspace.DesktopImageOptionKey: Any]?, _ rhs: [NSWorkspace.DesktopImageOptionKey: Any]
    ) -> Bool {
        let left = lhs ?? [:]
        return number(left[.imageScaling]) == number(rhs[.imageScaling])
            && number(left[.allowClipping]) == number(rhs[.allowClipping])
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? Bool).map { $0 ? 1 : 0 } ?? (value as? UInt).map(Double.init)
    }

    private static func original(_ url: URL, _ options: [NSWorkspace.DesktopImageOptionKey: Any]?)
        -> DesktopPictureMemory.Original
    {
        var stored: [String: Double] = [:]
        if let scaling = number(options?[.imageScaling]) { stored["imageScaling"] = scaling }
        if let clipping = number(options?[.allowClipping]) { stored["allowClipping"] = clipping }
        if let colour = (options?[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            stored["fillRed"] = colour.redComponent
            stored["fillGreen"] = colour.greenComponent
            stored["fillBlue"] = colour.blueComponent
            stored["fillAlpha"] = colour.alphaComponent
        }
        return DesktopPictureMemory.Original(path: url.path, options: stored)
    }

    private static func options(from stored: [String: Double]) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling = stored["imageScaling"].flatMap(UInt.init(exactly:)) { options[.imageScaling] = scaling }
        if let clipping = stored["allowClipping"] { options[.allowClipping] = clipping != 0 }
        if let red = stored["fillRed"], let green = stored["fillGreen"], let blue = stored["fillBlue"] {
            options[.fillColor] = NSColor(srgbRed: red, green: green, blue: blue, alpha: stored["fillAlpha"] ?? 1)
        }
        return options
    }

    private static func readMemory() -> DesktopPictureMemory {
        UserDefaults.standard.data(forKey: memoryKey)
            .flatMap { try? JSONDecoder().decode(DesktopPictureMemory.self, from: $0) } ?? DesktopPictureMemory()
    }

    private static func writeMemory(_ memory: DesktopPictureMemory) {
        if memory.originals.isEmpty {
            UserDefaults.standard.removeObject(forKey: memoryKey)
        } else {
            UserDefaults.standard.set(try? JSONEncoder().encode(memory), forKey: memoryKey)
        }
    }
}
