import Carbon
import os

/// The input sources of the menu bar's input menu, through Text Input Sources, a public part of Carbon that nothing has
/// replaced. Checked on macOS 27.2.
///
/// Nothing is kept: the list takes about 15 µs to ask for once the first call has loaded it, and a list kept would
/// miss a layout added in System Settings.
enum InputSources {
    private static let log = Logger(subsystem: "me.tweakly.Tweakly", category: "language-switch")

    /// Keyboard layouts and input modes that can be turned on, in the order of the input menu.
    static func selectable() -> [TISInputSource] {
        let filter =
            [
                kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                kTISPropertyInputSourceIsSelectCapable as String: true,
            ] as CFDictionary
        return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    static func identifier(of source: TISInputSource) -> String? {
        guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    static var currentIdentifier: String? {
        // The system can answer nothing, which unwrapped as it comes would stop the agent.
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return identifier(of: source)
    }

    /// - Returns: false if the system refused, which it does for a source that was removed a moment ago.
    @discardableResult
    static func select(_ source: TISInputSource) -> Bool {
        let status = TISSelectInputSource(source)
        if status != noErr {
            log.error("The system refused to select an input source: \(status, privacy: .public)")
        }
        return status == noErr
    }
}
