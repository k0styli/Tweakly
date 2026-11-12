# Contributing to Tweakly

Thanks for wanting to help. The most useful things right now are clear bug reports, ideas that fit the app, and translations.

## Issues

- **Bugs:** use the bug report form. The exact steps, your Mac and your macOS version are what make a bug fixable.
- **Ideas:** use the feature request form, or start a discussion if you're not sure yet.
- **Security:** see [SECURITY.md](SECURITY.md) and report privately.

## Pull requests

Open an issue before a pull request for anything bigger than a typo, so we can agree on the approach first. Tweakly holds itself to three rules, and a change has to keep all of them:

1. **Native.** Only system components, materials, fonts, colors and animations. No imitations of Liquid Glass, no custom controls where macOS has one.
2. **Minimal cost.** A feature that is off costs nothing: no timers, observers, threads or memory. Background work runs on events, not polling.
3. **Reliable.** A revoked permission, a missing private symbol, sleep, a display change or a new macOS version must not crash the app: the feature turns itself off and says why.

## Building

You need Xcode 27 with the macOS 26 SDK.

```bash
xcodebuild -project Tweakly.xcodeproj -scheme Tweakly -configuration Release -derivedDataPath build build
```

The logic of each feature lives in a Swift package under `Packages/`, with no system calls, so it can be tested on its own:

```bash
swift test --package-path Packages/SystemMetrics
swift test --package-path Packages/WindowSwitcherCore
```

A build signed by you gets permissions of its own, as macOS ties them to the signature.

## Code

- Swift 6 with strict concurrency, macOS 26 or later, Apple silicon only. APIs newer than macOS 26 go behind `#available`.
- AppKit for everything that lives in the menu bar or floats; SwiftUI only in the main window, which runs in its own short-lived process.
- No third-party dependencies.
- Private APIs are looked up at run time with `dlsym` in `Packages/SystemMetrics/Sources/SystemMetrics/PrivateBridge`, each with a fallback.
- Logic that can be tested gets a test in its package.
- Comments explain why, not what.
- Format with `xcrun swift-format format -i <files>` before committing.
- Commit messages follow `type(scope): summary`, for example `fix(stats): keep the graph after sleep`.

## Translations

Tweakly speaks English, Russian, German, Japanese and Simplified Chinese. Every new string goes into `Tweakly/Resources/Localizable.xcstrings` in all five at once. Words macOS itself uses are taken exactly as macOS translates them, so "Full Disk Access" is "Festplattenvollzugriff" in German and "フルディスクアクセス" in Japanese. Corrections and new languages are welcome as issues or pull requests.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
