import Darwin
import Foundation

/// Takes what the media cleaner wrote out of its job folder into a folder the cleaner cannot reach, so that nothing it
/// does afterwards changes what the library gets.
///
/// The cleaner is the part a hostile file may take over, and it keeps running after its reply. It may write anywhere in
/// the inbox: rename its job folder and leave a link in its place, or swap a file for a link, between any check and any
/// use. Every step here therefore works on what was opened, not on a path: the job folder is opened without following a
/// link and must still be the folder made for the job, each file is opened without following one and must be a plain
/// file with one name, and it is moved by the folder's descriptor and must arrive as the very file that was checked.
public enum CleanerOutput {
    public struct Refused: Error, Equatable {
        public let reason: String
    }

    /// The device and inode of a file or folder, which a rename does not change and a swap does.
    public struct Identity: Equatable, Sendable {
        public let device: dev_t
        public let inode: ino_t

        public init(device: dev_t, inode: ino_t) {
            self.device = device
            self.inode = inode
        }

        /// Of the path itself, never what a link there leads to.
        public init(of path: String) throws {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw Refused(reason: "\(path) cannot be read") }
            self.init(device: info.st_dev, inode: info.st_ino)
        }
    }

    /// Moves `names` from `job` into `destination`, a folder of the caller's own, under the same names.
    /// - Parameter folder: the identity `job` had when it was made for this job.
    public static func take(
        _ names: [String], from job: String, madeAs folder: Identity, into destination: String
    ) throws {
        let source = open(job, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw Refused(reason: "the job folder is not a folder") }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_dev == folder.device, info.st_ino == folder.inode else {
            throw Refused(reason: "the job folder is not the one made for the job")
        }
        let target = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { throw Refused(reason: "no folder to take the files into") }
        defer { close(target) }
        for name in names {
            guard MediaInbox.isPlainName(name) else { throw Refused(reason: "\(name) is not a plain name") }
            try take(name, from: source, into: target)
        }
    }

    private static func take(_ name: String, from source: Int32, into target: Int32) throws {
        let file = openat(source, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw Refused(reason: "\(name) is missing or a link") }
        defer { close(file) }
        var checked = stat()
        guard fstat(file, &checked) == 0, checked.st_mode & S_IFMT == S_IFREG, checked.st_nlink == 1 else {
            throw Refused(reason: "\(name) is not a plain file with one name")
        }
        if renameat(source, name, target, name) != 0 {
            // Another volume: a copy of the open file, which nothing can swap any more.
            guard errno == EXDEV else { throw Refused(reason: "\(name) could not be moved") }
            try copy(file, named: name, into: target)
            return
        }
        // What the name held when it was moved may not be what was checked: the cleaner could have swapped it in
        // between. Only the checked file is kept.
        var arrived = stat()
        guard fstatat(target, name, &arrived, AT_SYMLINK_NOFOLLOW) == 0, arrived.st_dev == checked.st_dev,
            arrived.st_ino == checked.st_ino, arrived.st_mode & S_IFMT == S_IFREG
        else {
            unlinkat(target, name, 0)
            throw Refused(reason: "\(name) changed while it was taken")
        }
        // Ordinary permissions whatever the cleaner gave it: read and write for its owner, never run.
        fchmod(file, 0o644)
    }

    private static func copy(_ file: Int32, named name: String, into target: Int32) throws {
        let copy = openat(target, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard copy >= 0 else { throw Refused(reason: "\(name) could not be copied") }
        defer { close(copy) }
        guard fcopyfile(file, copy, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            unlinkat(target, name, 0)
            throw Refused(reason: "\(name) could not be copied")
        }
    }
}
