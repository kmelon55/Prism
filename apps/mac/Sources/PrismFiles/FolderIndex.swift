import Darwin
import Foundation

/// An indexed file under one of the user's additional search folders.
struct IndexedFile: Sendable {
    let path: String
    let key: String
    let isDirectory: Bool

    var name: String { (path as NSString).lastPathComponent }
    var hit: FileHit { FileHit(path: path, isDirectory: isDirectory) }
}

/// An immutable filename catalog of the selected folders, ported from `library/file_index.rs`.
/// Directory listings are kept with their modification time so the next refresh rereads only folders that
/// changed. Queries never touch the disk.
final class FolderSnapshot: Sendable {
    struct Directory: Sendable {
        let modified: timespec?
        let entries: [IndexedFile]
    }

    static let maxFiles = 100_000
    static let maxDepth = 16

    let files: [IndexedFile]
    let limited: Bool
    let directories: [String: Directory]

    init(files: [IndexedFile], limited: Bool, directories: [String: Directory]) {
        self.files = files
        self.limited = limited
        self.directories = directories
    }

    static let empty = FolderSnapshot(files: [], limited: false, directories: [:])

    /// Matching files in rank order (normalized name, then path, within a rank), with the total match count.
    func page(_ query: FilenameQuery, filter: FileTypeFilter = .all, offset: Int = 0, limit: Int) -> (hits: [FileHit], total: Int) {
        var ranks = [UInt8](repeating: .max, count: files.count)
        var total = 0
        for (index, file) in files.enumerated() where filter.matches(name: file.name, isDirectory: file.isDirectory) {
            if let rank = query.rank(file.key) {
                ranks[index] = rank
                total += 1
            }
        }
        var page: [FileHit] = []
        var matched = 0
        for rank in UInt8(0)...4 {
            for (index, file) in files.enumerated() where ranks[index] == rank {
                if matched >= offset { page.append(file.hit) }
                matched += 1
                if page.count == limit { return (page, total) }
            }
        }
        return (page, total)
    }

    /// Walks `roots` breadth-first, bounded to `maxFiles` entries, depth 16 and `budget`. Skips excluded and
    /// hidden names, symbolic links and the contents of app bundles. A root that is not its own canonical
    /// path (moved or replaced by a link) is skipped and marks the result limited.
    static func scan(
        roots: [String], previous: FolderSnapshot? = nil, maxFiles: Int = maxFiles,
        budget: Duration = .seconds(5), isCancelled: () -> Bool = { false }
    ) -> FolderSnapshot {
        let clock = ContinuousClock()
        let started = clock.now
        var directories: [String: Directory] = [:]
        var files: [IndexedFile] = []
        var seen = Set<String>()
        var limited = false
        var visited = 0
        var queue: [(path: String, depth: Int)] = roots.map { ($0, 0) }
        var head = 0

        walk: while head < queue.count {
            let (path, depth) = queue[head]
            head += 1
            if isCancelled() { break }
            if clock.now - started >= budget { limited = true; break }

            if depth == 0, canonicalPath(path) != path { limited = true; continue }
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { limited = true; continue }
            let modified = info.st_mtimespec

            let directory: Directory
            var exhausted = false
            if let cached = previous?.directories[path], let cachedTime = cached.modified, cachedTime == modified {
                directory = cached
            } else {
                guard let handle = opendir(path) else { limited = true; continue }
                var rows: [IndexedFile] = []
                var partial = false
                while let entry = readdir(handle) {
                    visited += 1
                    if visited > maxFiles || isCancelled() || clock.now - started >= budget {
                        limited = true
                        exhausted = true
                        break
                    }
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                        String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                    }
                    if name == "." || name == ".." || FileSearchKey.isExcluded(name) { continue }
                    let type = Int32(entry.pointee.d_type)
                    let isDirectory: Bool
                    switch type {
                    case DT_DIR: isDirectory = true
                    case DT_REG: isDirectory = false
                    case DT_UNKNOWN:
                        var child = stat()
                        guard lstat(path + "/" + name, &child) == 0 else { partial = true; continue }
                        let mode = child.st_mode & S_IFMT
                        guard mode == S_IFDIR || mode == S_IFREG else { continue }
                        isDirectory = mode == S_IFDIR
                    default: continue // Links, sockets and devices.
                    }
                    let childPath = path == "/" ? "/" + name : path + "/" + name
                    rows.append(IndexedFile(path: childPath, key: FileSearchKey.make(name), isDirectory: isDirectory))
                }
                closedir(handle)
                // A partial listing must be reread next time even when its modification time is unchanged.
                directory = Directory(modified: exhausted || partial ? nil : modified, entries: rows)
                if partial { limited = true }
            }

            for file in directory.entries {
                if files.count >= maxFiles { limited = true; break walk }
                if seen.insert(file.path).inserted { files.append(file) }
                if file.isDirectory, !file.path.hasSuffix(".app") {
                    if depth < maxDepth { queue.append((file.path, depth + 1)) } else { limited = true }
                }
            }
            directories[path] = directory
            if exhausted { break }
        }
        files.sort { $0.key != $1.key ? $0.key < $1.key : $0.path < $1.path }
        return FolderSnapshot(files: files, limited: limited, directories: directories)
    }

    static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private func == (lhs: timespec, rhs: timespec) -> Bool {
    lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
}
