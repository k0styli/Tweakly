import AppKit
import FinderMenuCore
import os

/// Makes the file for New File. Finder's own New Folder picks the next free name in the same way, so this takes the
/// first name that is free at the moment of creating it, and never touches a file that is already there.
nonisolated enum NewFileMaker {
    /// Enough for any real folder, and a bound for one that is not.
    private static let attempts = 1000
    private static let queue = DispatchQueue(label: "me.tweakly.Tweakly.finder-menu.files", qos: .userInitiated)

    /// Runs off the main thread: the first file in Desktop, Documents or Downloads waits until the person has answered
    /// the system's question about access to that folder.
    static func make(
        _ name: NewFileName, in folder: String,
        then done: @escaping @MainActor @Sendable (Result<URL, POSIXError>) -> Void
    ) {
        queue.async {
            let result = create(name, in: folder)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    static func create(_ name: NewFileName, in folder: String) -> Result<URL, POSIXError> {
        // Every name is taken relative to the folder opened here, so a folder renamed or replaced meanwhile cannot send
        // the file anywhere else.
        let directory = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return .failure(POSIXError(errno)) }
        defer { close(directory) }
        for candidate in name.candidates(limit: attempts) {
            // O_EXCL refuses a name that exists in any case or form the volume treats as the same, and a link.
            let file = openat(directory, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            if file >= 0 {
                close(file)
                return .success(URL(filePath: folder, directoryHint: .isDirectory).appending(path: candidate))
            }
            guard errno == EEXIST else { return .failure(POSIXError(errno)) }
        }
        return .failure(POSIXError(.EEXIST))
    }
}

extension POSIXError {
    fileprivate init(_ code: Int32) {
        self.init(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
