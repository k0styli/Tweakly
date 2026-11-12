import CoreFoundation
import Darwin

/// PRIVATE INTERFACE. How macOS stands on one of this app's privacy permissions, read without asking for it.
///
/// Public API has a question without a prompt only for Accessibility, Screen Recording and Input Monitoring. For System
/// Audio Recording and for the Desktop, Documents and Downloads folders the only public way to find out is to use them,
/// which shows the request. `TCCAccessPreflight` in TCC.framework answers for the calling process as tccd sees it, and
/// shows nothing. Checked on macOS 27.2 on an M2: 0 allowed, 1 denied, 2 not asked yet. Approved by the owner on
/// 2026-11-12 for the Permissions page. Without the symbol the page says macOS asks on first use, as it did before.
public enum PrivacyPreflight {
    public enum Answer: Equatable, Sendable {
        case allowed
        case denied
        case notAsked
    }

    public enum Service: String, CaseIterable, Sendable {
        case audioCapture = "kTCCServiceAudioCapture"
        case desktopFolder = "kTCCServiceSystemPolicyDesktopFolder"
        case documentsFolder = "kTCCServiceSystemPolicyDocumentsFolder"
        case downloadsFolder = "kTCCServiceSystemPolicyDownloadsFolder"
    }

    /// A function pointer looked up once and never changed, which is what makes sharing it safe.
    private struct Symbols: @unchecked Sendable {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
        let preflight: Preflight?

        init() {
            let library = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY)
            preflight = PrivateSymbols.find("TCCAccessPreflight", in: library).map {
                unsafeBitCast($0, to: Preflight.self)
            }
        }
    }

    private static let symbols = Symbols()

    /// Nil when the question cannot be asked on this system, or the answer is one this code does not know.
    public static func answer(for service: Service) -> Answer? {
        guard let preflight = symbols.preflight else { return nil }
        return answer(code: preflight(service.rawValue as CFString, nil))
    }

    /// What tccd's number means. Anything else is a value a newer macOS added, which is better left unread.
    static func answer(code: Int32) -> Answer? {
        switch code {
        case 0: .allowed
        case 1: .denied
        case 2: .notAsked
        default: nil
        }
    }
}
