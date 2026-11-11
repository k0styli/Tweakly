# Tweakly

The small things macOS left out, in one native app. Fifteen features, from your Mac's load in the menu bar to a task manager and live wallpaper. Each one turns on by itself, and one that is off uses nothing: no timers, no observers, no memory.

Tweakly is built only from system components, materials and fonts, so it looks and behaves like part of macOS.

## Features

**Menu bar**
- **Stats**: CPU, graphics, memory, disk, network and battery, each with its own icon, style and update rate. A click opens a panel with a graph and what is keeping the Mac busy.
- **Simple View**: one icon instead of six, with a panel of rings or a list. The icon can be the gear, a cat or a file of your own, and can fill up with the load.
- **Fans**: five profiles, a fixed speed or your own curve that follows the sensor you pick, per fan and on battery.
- **Volume Mixer**: the overall volume and output, and a volume from 0 to 200 % and an output for each app that is playing.

**Windows**
- **Window Switcher**: Cmd-Tab with a tile and a preview for every window, minimized ones and those on other desktops too.
- **Dock Previews**: point at a Dock icon and the app's windows appear above it; click the icon of an open app to minimize it.

**Utilities**
- **Task Manager**: every process in one table with CPU, memory, disk, network and GPU, split into apps, background and system processes.
- **App Uninstaller**: removes an app with its settings, caches, data, containers and background services, all to the Trash.
- **Keyboard Cleaning**: the keyboard turns off for a while so you can wipe it; the trackpad and mouse keep working.

**Desktop**
- **Live Wallpaper**: videos and pictures on the desktop, your own library and a browser of wallpaper sites. A video plays only while someone can see it.

**Input and Finder**
- **Mouse**: a pointer without acceleration at a speed of your own, a wheel separate from the trackpad, Back and Forward on the side buttons.
- **Language Switch**: a short press of Fn switches to the previous input source.
- **Cut in Finder**: cut and paste files from the keyboard; Finder moves them itself.
- **Finder Menu**: New File, Copy Path and Open in Terminal on the right click.

## Requirements

macOS 26 or later on a Mac with Apple silicon.

## Install

Download the disk image from [Releases](../../releases), open it and drag Tweakly to Applications. Releases are signed with Developer ID and notarized by Apple.

Tweakly asks for a permission only when you turn on a feature that needs it, and says why. If a permission is taken back, the feature switches itself off and tells you.

## Build from source

You need Xcode 27 with the macOS 26 SDK.

```bash
xcodebuild -project Tweakly.xcodeproj -scheme Tweakly -configuration Release -derivedDataPath build build
```

`Tools/install.sh` builds Tweakly and installs it to `/Applications` under a signature that stays the same from build to build, so macOS keeps its permissions across updates. It uses a Developer ID certificate when the keychain has one and otherwise makes a local certificate for this Mac alone.

The logic of each feature lives in a Swift package under `Packages/` with its own tests:

```bash
swift test --package-path Packages/SystemMetrics
```

## License

[MIT](LICENSE)
