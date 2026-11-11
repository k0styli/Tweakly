import AppKit

// The same executable runs as the menu bar agent or, when asked, as the short-lived window process.
// A third role plays live wallpapers, see `WallpaperProcess`, and a fourth apps' sound, see `AudioProcess`.
let delegate: NSApplicationDelegate =
    if WallpaperProcess.isWallpaperProcess {
        WallpaperAppDelegate()
    } else if AudioProcess.isAudioProcess {
        AudioAppDelegate()
    } else if WindowProcess.isWindowProcess {
        WindowAppDelegate()
    } else {
        AppDelegate()
    }
NSApplication.shared.delegate = delegate
#if TWEAKLY_AUTOMATION
    QuietScreen.start()
#endif
NSApplication.shared.run()
