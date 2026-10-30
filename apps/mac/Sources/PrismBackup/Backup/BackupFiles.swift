import Darwin
import Foundation

/// Bounded, symlink-safe reading and atomic, owner-only writing of backup files (`read_file`/`write_file` in
/// `library_backup.rs`, `raycast_write_journal` in `migration_journal.rs`).
enum BackupFiles {
    /// Refuses symlinks, directories, FIFOs and files over `limit` without following or blocking on them.
    static func read(_ url: URL, limit: Int = BackupDocument.maxBytes, readError: String = BackupMessage.readError,
                     invalidError: String = BackupMessage.invalid, tooLarge: String = BackupMessage.tooLarge) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupError(readError) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw BackupError(readError) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw BackupError(invalidError) }
        guard info.st_size <= off_t(limit) else { throw BackupError(tooLarge) }
        var data = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, chunk) }
            if count < 0 {
                if errno == EINTR { continue }
                throw BackupError(readError)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit { throw BackupError(tooLarge) }
        }
        return data
    }

    /// Writes an exclusive sibling temporary file (mode 0600), syncs it, then renames it over `url`. On failure the
    /// temporary file is removed and the previous destination is left as it was.
    static func write(_ data: Data, to url: URL, limit: Int = BackupDocument.maxBytes, writeError: String = BackupMessage.writeError,
                      tooLarge: String = BackupMessage.tooLarge) throws {
        guard data.count <= limit else { throw BackupError(tooLarge) }
        let directory = url.deletingLastPathComponent()
        var temporary: (path: String, descriptor: Int32)?
        for index in 0..<100 {
            let path = directory.appending(path: ".prism-backup-\(getpid())-\(index).tmp").path
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if descriptor >= 0 {
                temporary = (path, descriptor)
                break
            }
            if errno != EEXIST { throw BackupError(writeError) }
        }
        guard let (path, descriptor) = temporary else { throw BackupError(writeError) }
        var succeeded = false
        defer {
            if !succeeded { unlink(path) }
        }
        let written = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        let synced = written && fsync(descriptor) == 0
        close(descriptor)
        guard synced, rename(path, url.path) == 0 else { throw BackupError(writeError) }
        succeeded = true
    }
}
