import Foundation
import CryptoKit
import Darwin

typealias DuplicateFileIdentity = CleanupIdentity

struct DuplicateGroup: Identifiable {
    let id: String
    /// The first copy is the suggested keeper. Nothing is selected or removed here.
    let entries: [CatalogEntry]
    let bytesPerCopy: Int64
    let fingerprints: [String: DuplicateFileIdentity]
    /// Allocated bytes in the other copies; APFS sharing can reduce actual recovery.
    var reclaimableBytes: Int64 { entries.dropFirst().reduce(0) { $0 + $1.bytes } }
}

struct DuplicateScanResult {
    let groups: [DuplicateGroup]
    /// Files excluded by safety policy or unavailable in candidate size groups.
    let skipped: Int
    let cancelled: Bool
}

enum DuplicateCleanupError: LocalizedError {
    case unknownSelection(String), changed(String), missingKeeper(String)
    var errorDescription: String? {
        switch self {
        case .unknownSelection(let path): return "Verify duplicates again before selecting this file: \(path)"
        case .changed(let path): return "This file changed after verification. Verify duplicates again: \(path)"
        case .missingKeeper(let path): return "An unchanged original must remain. Deselect a copy or verify this group again: \(path)"
        }
    }
}

/// Content verification is deliberately separate from the metadata-only scan.
/// This reads local regular files in bounded chunks and never downloads placeholders.
enum DuplicateFinder {
    static let minimumFileBytes: Int64 = 1_024 * 1_024
    private static let chunkSize = 1_024 * 1_024

    private struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino }
    }

    private struct VerifiedFile {
        let entry: CatalogEntry
        let metadata: stat
    }

    private enum VerificationError: Error { case unsafe, changed, cancelled }

    private final class OpenFile {
        let descriptor: Int32
        let parent: Int32
        let name: String
        let metadata: stat
        init(descriptor: Int32, parent: Int32, name: String, metadata: stat) {
            self.descriptor = descriptor; self.parent = parent
            self.name = name; self.metadata = metadata
        }
        deinit { close(descriptor); close(parent) }

        func unchanged() -> Bool {
            var current = stat(), named = stat()
            guard fstat(descriptor, &current) == 0,
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            return DuplicateFinder.sameFile(metadata, current) && DuplicateFinder.sameFile(metadata, named)
        }
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_mode == second.st_mode
            && first.st_size == second.st_size && first.st_nlink == second.st_nlink
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
            && first.st_birthtimespec.tv_sec == second.st_birthtimespec.tv_sec
            && first.st_birthtimespec.tv_nsec == second.st_birthtimespec.tv_nsec
            && first.st_flags == second.st_flags
    }

    private static func isManagedContent(_ path: String) -> Bool {
        let extensions: Set<String> = ["app", "photoslibrary", "photolibrary", "musiclibrary", "framework", "bundle"]
        return path.split(separator: "/").contains { component in
            let name = String(component).lowercased()
            return [".git", ".trash", ".trashes"].contains(name)
                || extensions.contains((name as NSString).pathExtension)
        }
    }

    /// Open each directory by descriptor, so replacing an ancestor with a symbolic
    /// link cannot redirect the read. Catalog paths are already canonicalized by
    /// the scanner; a subsequently introduced symlink is rejected, never resolved.
    private static func openSafely(_ entry: CatalogEntry) throws -> OpenFile {
        guard entry.path.hasPrefix("/"), !entry.path.utf8.contains(0) else { throw VerificationError.unsafe }
        let components = entry.path.split(separator: "/").map(String.init)
        guard let name = components.last,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw VerificationError.unsafe }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw VerificationError.unsafe }
        var transferParent = false
        defer { if !transferParent { close(directory) } }
        for component in components.dropLast() {
            var before = stat()
            guard fstatat(directory, component, &before, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_mode & S_IFMT == S_IFDIR,
                  before.st_flags & UInt32(SF_DATALESS) == 0 else { throw VerificationError.unsafe }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw VerificationError.unsafe }
            var after = stat()
            guard fstat(next, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  after.st_mode & S_IFMT == S_IFDIR, after.st_flags & UInt32(SF_DATALESS) == 0 else {
                close(next); throw VerificationError.unsafe
            }
            close(directory); directory = next
        }
        var before = stat()
        guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_flags & UInt32(SF_DATALESS) == 0,
              before.st_nlink == 1,
              Int64(before.st_size) == entry.logicalBytes,
              Double(before.st_mtimespec.tv_sec) == entry.modified.timeIntervalSince1970.rounded(.down)
        else { throw VerificationError.unsafe }
        // This is metadata only. It prevents an explicit verification from
        // hydrating an iCloud item whose file provider does not set SF_DATALESS.
        let resources = try entry.url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if resources.isUbiquitousItem == true {
            guard resources.ubiquitousItemDownloadingStatus == .downloaded
                    || resources.ubiquitousItemDownloadingStatus == .current else { throw VerificationError.unsafe }
        }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw VerificationError.unsafe }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameFile(before, after) else {
            close(descriptor); throw VerificationError.changed
        }
        transferParent = true
        return OpenFile(descriptor: descriptor, parent: directory, name: name, metadata: after)
    }

    private static func digest(_ file: OpenFile, isCancelled: () -> Bool, report: () -> Void) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var remaining = Int64(file.metadata.st_size)
        while remaining > 0 {
            guard !isCancelled() else { throw VerificationError.cancelled }
            report()
            let count = buffer.withUnsafeMutableBytes { raw in
                read(file.descriptor, raw.baseAddress, min(raw.count, Int(remaining)))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw VerificationError.changed }
            buffer.withUnsafeBytes { raw in hasher.update(data: Data(raw.prefix(count))) }
            remaining -= Int64(count)
        }
        guard !isCancelled() else { throw VerificationError.cancelled }
        guard file.unchanged() else { throw VerificationError.changed }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func find(entries: [CatalogEntry], isCancelled: () -> Bool = { false },
                     onProgress: (String) -> Void = { _ in }) -> DuplicateScanResult {
        guard !isCancelled() else { return DuplicateScanResult(groups: [], skipped: 0, cancelled: true) }
        var skipped = 0
        let eligible = entries.filter {
            guard !$0.isDirectory && $0.logicalBytes >= minimumFileBytes else { return false }
            if isManagedContent($0.path) { skipped += 1; return false }
            return true
        }
        let buckets = Dictionary(grouping: eligible, by: \.logicalBytes)
        var seen = Set<Identity>()
        var verified: [String: [VerifiedFile]] = [:]
        var lastProgress: TimeInterval = -.infinity
        var cancelled = false
        func report(_ path: String) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastProgress >= 0.25 { lastProgress = now; onProgress(path) }
        }
        for size in buckets.keys.sorted(by: >) {
            // Unique sizes cannot contain a content duplicate and need no reads.
            guard let candidates = buckets[size], candidates.count > 1 else { continue }
            for entry in candidates.sorted(by: { $0.path < $1.path }) {
                if isCancelled() { cancelled = true; break }
                do {
                    guard !entry.isSymbolicLink, entry.unreadable == 0 else { throw VerificationError.unsafe }
                    let file = try openSafely(entry)
                    guard seen.insert(Identity(file.metadata)).inserted else { throw VerificationError.unsafe }
                    let hash = try digest(file, isCancelled: isCancelled, report: { report(entry.path) })
                    verified["\(size):\(hash)", default: []].append(VerifiedFile(entry: entry, metadata: file.metadata))
                } catch VerificationError.cancelled { cancelled = true; break }
                catch { skipped += 1 }
            }
            if cancelled { break }
        }
        // Recheck matching files after the pass: edits made while another large
        // file was being hashed must not appear as verified duplicate candidates.
        var groups: [DuplicateGroup] = []
        if !cancelled {
            for key in verified.keys.sorted() {
                guard let matches = verified[key], matches.count > 1 else { continue }
                var unchanged: [CatalogEntry] = []
                var fingerprints: [String: DuplicateFileIdentity] = [:]
                for candidate in matches {
                    if isCancelled() { cancelled = true; break }
                    do {
                        let file = try openSafely(candidate.entry)
                        guard sameFile(candidate.metadata, file.metadata), file.unchanged() else { throw VerificationError.changed }
                        unchanged.append(candidate.entry)
                        fingerprints[candidate.entry.path] = DuplicateFileIdentity(metadata: candidate.metadata)
                    } catch { skipped += 1 }
                }
                if cancelled { break }
                if unchanged.count > 1 {
                    groups.append(DuplicateGroup(id: key, entries: unchanged,
                        bytesPerCopy: unchanged[0].logicalBytes, fingerprints: fingerprints))
                }
            }
        }
        // A cancelled pass has incomplete coverage; never surface partial groups
        // as though verification finished successfully.
        cancelled = cancelled || isCancelled()
        return DuplicateScanResult(groups: cancelled ? [] : groups.sorted {
            $0.reclaimableBytes == $1.reclaimableBytes ? $0.id < $1.id : $0.reclaimableBytes > $1.reclaimableBytes
        }, skipped: skipped, cancelled: cancelled)
    }

    /// Run again before confirmation as well as before review. Checks both the
    /// selected copies and at least one unselected original in each affected group.
    /// The returned candidates retain hash-time identities, so CleanupService
    /// also rejects in-place edits between review and the eventual Trash move.
    static func validateForCleanup(entries: [CatalogEntry], groups: [DuplicateGroup]) throws -> [CleanupCandidate] {
        let selected = Set(entries.map(\.path))
        guard !selected.isEmpty else { return [] }
        let knownPaths = Set(groups.flatMap { $0.entries.map(\.path) })
        if let unknown = selected.subtracting(knownPaths).sorted().first {
            throw DuplicateCleanupError.unknownSelection(unknown)
        }
        var candidates: [CleanupCandidate] = []
        for group in groups where group.entries.contains(where: { selected.contains($0.path) }) {
            let keepers = group.entries.filter { !selected.contains($0.path) }
            let keeperExists = keepers.contains { entry in
                guard let expected = group.fingerprints[entry.path], let file = try? openSafely(entry) else { return false }
                return DuplicateFileIdentity(metadata: file.metadata) == expected && file.unchanged()
            }
            guard keeperExists else {
                throw DuplicateCleanupError.missingKeeper(group.entries.first?.name ?? "Duplicate group")
            }
            for entry in group.entries where selected.contains(entry.path) {
                guard !isManagedContent(entry.path), let expected = group.fingerprints[entry.path],
                      let file = try? openSafely(entry),
                      DuplicateFileIdentity(metadata: file.metadata) == expected, file.unchanged()
                else { throw DuplicateCleanupError.changed(entry.path) }
                candidates.append(CleanupCandidate(url: entry.url, bytes: entry.bytes,
                    reason: "Verified duplicate; an unchanged original will remain", expectedIdentity: expected))
            }
        }
        return candidates.sorted { $0.url.path < $1.url.path }
    }
}
