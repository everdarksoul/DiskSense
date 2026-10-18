import Foundation
import Darwin

/// A value snapshot: background scans never mutate observable UI nodes.
struct ScannedEntry {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let bytes: Int64
    let unreadable: Int
}

struct DirectoryScanResult {
    let url: URL
    let children: [ScannedEntry]
    let bytes: Int64
    let unreadable: Int
    let cancelled: Bool
}

/// Measures allocated storage, including hidden files and bundle contents.
/// Symbolic links are measured themselves; traversal stays on the starting device.
final class DiskScanner {
    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private final class Walk {
        let device: dev_t
        let isCancelled: () -> Bool
        let progress: (String) -> Void
        var seen = Set<Identity>()
        var seenDirectories = Set<Identity>()
        var lastProgress: TimeInterval = 0
        let catalog: ScanWriter?

        init(device: dev_t, isCancelled: @escaping () -> Bool, progress: @escaping (String) -> Void, catalog: ScanWriter? = nil) {
            self.device = device
            self.isCancelled = isCancelled
            self.progress = progress
            self.catalog = catalog
        }

        func report(_ path: @autoclosure () -> String) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.25 { lastProgress = now; progress(path()) }
        }
    }

    private func info(_ url: URL) -> stat? {
        var value = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            path.map { lstat($0, &value) } ?? -1
        }
        return result == 0 ? value : nil
    }

    private func isDirectory(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFDIR
    }

    private func isLink(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFLNK
    }

    private func allocated(info value: stat, walk: Walk) -> Int64 {
        // Multiple hard links consume one allocation. APFS clone/snapshot sharing
        // is not exposed per file, so this is allocated usage, not a reclaim promise.
        if !isDirectory(value), value.st_nlink > 1 {
            guard walk.seen.insert(Identity(device: value.st_dev, inode: value.st_ino)).inserted else { return 0 }
        }
        // st_blocks is the filesystem's allocated 512-byte block count (the
        // same basis as du). Avoid Foundation resource lookups for every file:
        // those create cached metadata objects even when we only need a number.
        return Int64(value.st_blocks) * 512
    }

    private func isPlaceholder(_ url: URL, info value: stat) -> Bool {
        // Reading metadata does not request a download. Never open file content.
        if value.st_flags & UInt32(SF_DATALESS) != 0 { return true }
        let resources = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return resources?.isUbiquitousItem == true && resources?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    private struct DirectoryFrame {
        let path: String
        let value: stat
        var bytes: Int64
        var unreadable: Int
    }

    private func catalogEntry(path: String, value: stat?, bytes: Int64, unreadable: Int, directory: Bool? = nil) -> CatalogEntry {
        let name = (path as NSString).lastPathComponent
        let isDir = directory ?? value.map { isDirectory($0) } ?? false
        let packageExtensions: Set<String> = ["app", "bundle", "framework", "photoslibrary", "xcodeproj", "playground", "pkg"]
        return CatalogEntry(path: path, parent: (path as NSString).deletingLastPathComponent, name: name,
            isDirectory: isDir, isPackage: isDir && packageExtensions.contains((name as NSString).pathExtension.lowercased()),
            bytes: bytes, logicalBytes: isDir ? 0 : Int64(value?.st_size ?? 0),
            modified: Date(timeIntervalSince1970: Double(value?.st_mtimespec.tv_sec ?? 0)),
            unreadable: unreadable, category: StorageCategory.classify(path: path, isDirectory: isDir),
            isSymbolicLink: value.map { isLink($0) } ?? false)
    }

    private func measureNode(_ url: URL, info value: stat, walk: Walk) -> (bytes: Int64, unreadable: Int) {
        guard !walk.isCancelled(), value.st_dev == walk.device else { return (0, 0) }
        // macOS exposes this reserved backing-store namespace through a
        // synthetic root entry. It is not an additional user-data location.
        if url.path == "/.nofollow" { return (0, 0) }
        if walk.catalog?.excludes(url.path) == true { return (0, 0) }
        if !isDirectory(value) || isLink(value) || isPlaceholder(url, info: value) {
            let bytes = allocated(info: value, walk: walk)
            walk.catalog?.record(catalogEntry(path: url.path, value: value, bytes: bytes, unreadable: 0))
            return (bytes, 0)
        }
        // Physical BSD traversal provides stat metadata with each entry, avoids
        // per-file URL resource allocation and never changes the process cwd.
        let path = strdup(url.path)
        defer { free(path) }
        var paths: [UnsafeMutablePointer<CChar>?] = [path, nil]
        let stream = paths.withUnsafeMutableBufferPointer { fts_open($0.baseAddress, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) }
        guard let stream else {
            walk.catalog?.record(catalogEntry(path: url.path, value: value, bytes: Int64(value.st_blocks) * 512, unreadable: 1))
            return (Int64(value.st_blocks) * 512, 1)
        }
        defer { fts_close(stream) }
        var total: Int64 = 0
        var unreadable = 0
        var stack: [DirectoryFrame] = []
        while !walk.isCancelled(), let pointer = fts_read(stream) {
            autoreleasepool {
                let node = pointer.pointee
                let kind = Int32(node.fts_info)
                let path = String(cString: node.fts_path)
                if walk.catalog?.excludes(path) == true { fts_set(stream, pointer, FTS_SKIP); return }
                if kind == FTS_DP {
                    if let last = stack.last, last.path == path {
                        let frame = stack.removeLast()
                        walk.catalog?.record(catalogEntry(path: path, value: frame.value, bytes: frame.bytes, unreadable: frame.unreadable))
                        if !stack.isEmpty { stack[stack.count - 1].bytes += frame.bytes; stack[stack.count - 1].unreadable += frame.unreadable }
                    }
                    return
                }
                if kind == FTS_DOT || kind == FTS_DC { return }
                let metadata: stat? = kind == FTS_NS || kind == FTS_ERR ? nil : node.fts_statp?.pointee
                if let metadata, metadata.st_dev != walk.device { fts_set(stream, pointer, FTS_SKIP); return }
                walk.report(path)
                if kind == FTS_D, let metadata {
                    guard walk.seenDirectories.insert(Identity(device: metadata.st_dev, inode: metadata.st_ino)).inserted else {
                        fts_set(stream, pointer, FTS_SKIP)
                        return
                    }
                    let bytes = Int64(metadata.st_blocks) * 512
                    total += bytes
                    if walk.catalog != nil { stack.append(DirectoryFrame(path: path, value: metadata, bytes: bytes, unreadable: 0)) }
                    if metadata.st_flags & UInt32(SF_DATALESS) != 0 { fts_set(stream, pointer, FTS_SKIP) }
                    return
                }
                let error = [FTS_DNR, FTS_ERR, FTS_NS].contains(kind) ? 1 : 0
                unreadable += error
                if let last = stack.last, last.path == path {
                    var frame = stack.removeLast(); frame.unreadable += error
                    walk.catalog?.record(catalogEntry(path: path, value: frame.value, bytes: frame.bytes, unreadable: frame.unreadable))
                    if !stack.isEmpty { stack[stack.count - 1].bytes += frame.bytes; stack[stack.count - 1].unreadable += frame.unreadable }
                    return
                }
                let bytes = metadata.map { allocated(info: $0, walk: walk) } ?? 0
                total += bytes
                walk.catalog?.record(catalogEntry(path: path, value: metadata, bytes: bytes, unreadable: error, directory: kind == FTS_DNR ? true : nil))
                if !stack.isEmpty { stack[stack.count - 1].bytes += bytes; stack[stack.count - 1].unreadable += error }
            }
        }
        return (total, unreadable)
    }

    func scanDirectory(at url: URL,
                       onProgress: @escaping (String) -> Void = { _ in },
                       isCancelled: @escaping () -> Bool = { false },
                       onEntry: ((ScannedEntry) -> Void)? = nil,
                       catalog: ScanWriter? = nil) -> DirectoryScanResult {
        let url = ScanStore.canonical(url)
        guard !isCancelled() else {
            return DirectoryScanResult(url: url, children: [], bytes: 0, unreadable: 0, cancelled: true)
        }
        guard let rootInfo = info(url) else {
            return DirectoryScanResult(url: url, children: [], bytes: 0, unreadable: 1, cancelled: false)
        }
        let walk = Walk(device: rootInfo.st_dev, isCancelled: isCancelled, progress: onProgress, catalog: catalog)
        walk.seenDirectories.insert(Identity(device: rootInfo.st_dev, inode: rootInfo.st_ino))
        guard isDirectory(rootInfo), !isLink(rootInfo), !isPlaceholder(url, info: rootInfo) else {
            return DirectoryScanResult(url: url, children: [], bytes: allocated(info: rootInfo, walk: walk), unreadable: 0, cancelled: false)
        }
        var bytes = allocated(info: rootInfo, walk: walk)
        var unreadable = 0
        var children: [ScannedEntry] = []
        walk.report(url.path)
        do {
            // No skipsHiddenFiles or skipsPackageDescendants: both hold real data.
            let entries = try autoreleasepool {
                // Surface useful results before large hidden developer caches.
                // This affects completion order only; final rows sort by size.
                let priority = ["Downloads": 0, "Desktop": 1, "Documents": 2, "Applications": 3]
                return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [], options: [])
                    .sorted { lhs, rhs in
                        let left = lhs.lastPathComponent
                        let right = rhs.lastPathComponent
                        let leftHidden = left.hasPrefix(".")
                        let rightHidden = right.hasPrefix(".")
                        if leftHidden != rightHidden { return !leftHidden }
                        let leftPriority = priority[left] ?? 4
                        let rightPriority = priority[right] ?? 4
                        if leftPriority != rightPriority { return leftPriority < rightPriority }
                        return left < right
                    }
            }
            for entry in entries {
                if isCancelled() { break }
                autoreleasepool {
                    let value = info(entry)
                    let measured = value.map { measureNode(entry, info: $0, walk: walk) } ?? (bytes: 0, unreadable: 1)
                    let directory = value.map { isDirectory($0) && !isLink($0) } ?? false
                    let snapshot = ScannedEntry(url: entry, name: entry.lastPathComponent,
                        isDirectory: directory,
                        isPackage: directory && ((try? entry.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false),
                        bytes: measured.bytes, unreadable: measured.unreadable)
                    children.append(snapshot)
                    bytes += measured.bytes
                    unreadable += measured.unreadable
                    onEntry?(snapshot)
                }
            }
        } catch { unreadable += 1 }
        catalog?.record(catalogEntry(path: url.path, value: rootInfo, bytes: bytes, unreadable: unreadable))
        children.sort { $0.bytes == $1.bytes ? $0.name < $1.name : $0.bytes > $1.bytes }
        return DirectoryScanResult(url: url, children: children, bytes: bytes, unreadable: unreadable, cancelled: isCancelled())
    }

    func measure(at url: URL, isCancelled: @escaping () -> Bool = { false }) -> (bytes: Int64, unreadable: Int) {
        autoreleasepool {
            guard !isCancelled() else { return (0, 0) }
            guard let value = info(url) else { return (0, 1) }
            return measureNode(url, info: value, walk: Walk(device: value.st_dev, isCancelled: isCancelled, progress: { _ in }))
        }
    }

    /// Compatibility adapter for callers that own their ScanItem mutation queue.
    func sizeChildren(of parent: ScanItem, completion: @escaping ([ScanItem], Int64, Int) -> Void) {
        let result = scanDirectory(at: parent.url)
        let items = result.children.map { entry -> ScanItem in
            let item = ScanItem(url: entry.url, name: entry.name, isDirectory: entry.isDirectory,
                                isPackage: entry.isPackage, depth: parent.depth + 1)
            item.allocatedBytes = entry.bytes
            item.isUnreadable = entry.unreadable > 0
            return item
        }
        completion(items, result.bytes, result.unreadable)
    }

    func sweep(root: URL, onProgress: @escaping (String) -> Void) -> (bytes: Int64, unreadable: Int) {
        guard let value = info(root) else { return (0, 1) }
        return measureNode(root, info: value, walk: Walk(device: value.st_dev, isCancelled: { false }, progress: onProgress))
    }

    static func overview(for path: String) -> DiskOverview {
        var overview = DiskOverview()
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            overview.volumeName = values.volumeName ?? "Storage volume"
            overview.totalCapacity = Int64(values.volumeTotalCapacity ?? 0)
            overview.freeSpace = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        }
        overview.needsFullDiskAccess = FullDiskAccess.status() == .denied
        return overview
    }
}
