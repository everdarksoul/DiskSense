import AppKit
import Foundation
import Darwin

struct CleanupIdentity: Codable, Hashable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int
    let contentSize: Int64?
    let modifiedSeconds: Int?
    let modifiedNanoseconds: Int?
    let changedSeconds: Int?
    let changedNanoseconds: Int?

    init(metadata: stat) {
        device = metadata.st_dev; inode = metadata.st_ino
        birthSeconds = metadata.st_birthtimespec.tv_sec
        birthNanoseconds = metadata.st_birthtimespec.tv_nsec
        let regular = metadata.st_mode & S_IFMT == S_IFREG
        contentSize = regular ? Int64(metadata.st_size) : nil
        modifiedSeconds = regular ? metadata.st_mtimespec.tv_sec : nil
        modifiedNanoseconds = regular ? metadata.st_mtimespec.tv_nsec : nil
        changedSeconds = regular ? metadata.st_ctimespec.tv_sec : nil
        changedNanoseconds = regular ? metadata.st_ctimespec.tv_nsec : nil
    }
}

/// A specific item selected by the user. A scan alone never authorizes cleanup.
struct CleanupCandidate: Identifiable, Hashable {
    let url: URL
    let bytes: Int64
    let reason: String
    let expectedIdentity: CleanupIdentity?
    var id: String { url.path }
    init(url: URL, bytes: Int64, reason: String, expectedIdentity: CleanupIdentity? = nil) {
        self.url = url; self.bytes = bytes; self.reason = reason; self.expectedIdentity = expectedIdentity
    }
}

struct CleanupResult {
    let moved: [URL]
    let failures: [String]
    var receipts: [TrashReceipt] = []
}

enum CleanupError: LocalizedError {
    case unsafePath(String)
    case missingPath(String)
    case runningApplication(String)
    case changedPath(String)
    case unverifiedTrash(String)
    case changedTrash(String)

    var errorDescription: String? {
        switch self {
        case .unsafePath(let path): return "Protected location cannot be moved to Trash: \(path)"
        case .missingPath(let path): return "Item no longer exists: \(path)"
        case .changedPath(let path): return "This item changed after review. Review it again before removing: \(path)"
        case .unverifiedTrash(let path): return "This older cleanup record cannot verify the item in Trash. Inspect and restore it through Finder: \(path)"
        case .changedTrash(let path): return "The item at this Trash location no longer matches the cleanup record. Inspect and restore it through Finder: \(path)"
        case .runningApplication(let path): return "Quit the application before moving it to Trash: \(path)"
        }
    }
}

/// Uses the system Trash, preserving Finder's recovery behavior. Run off the main thread.
final class CleanupService {
    typealias TrashOperation = (URL) throws -> Void
    private let fm: FileManager
    private let home: URL
    private let allowedRoots: [URL]
    private let ownApplicationURL: URL
    private let runningApplicationURLs: () -> [URL]
    private let trashOperation: TrashOperation?

    init(fileManager: FileManager = .default,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         ownApplicationURL: URL = Bundle.main.bundleURL,
         allowedRoots: [URL] = [],
         runningApplicationURLs: @escaping () -> [URL] = {
             NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
         },
         trashOperation: TrashOperation? = nil) {
        fm = fileManager
        home = Self.normalizeDataAlias(homeDirectory.resolvingSymlinksInPath().standardizedFileURL)
        self.allowedRoots = allowedRoots.map { Self.normalizeDataAlias($0.resolvingSymlinksInPath().standardizedFileURL) }
        self.ownApplicationURL = Self.normalizeDataAlias(ownApplicationURL.resolvingSymlinksInPath().standardizedFileURL)
        self.runningApplicationURLs = runningApplicationURLs
        self.trashOperation = trashOperation
    }

    /// Reject unsafe selections, then collapse duplicates and children of selected folders.
    /// Resolve ancestor symlinks, while retaining a final symlink so only the link is trashed.
    func validate(_ candidates: [CleanupCandidate]) throws -> [CleanupCandidate] {
        let running = runningApplicationURLs().map { Self.normalizeDataAlias($0.resolvingSymlinksInPath().standardizedFileURL) }
        var unique: [String: CleanupCandidate] = [:]
        for candidate in candidates {
            guard candidate.url.isFileURL else { throw CleanupError.unsafePath(candidate.url.absoluteString) }
            let original = candidate.url.standardizedFileURL
            let resolved = Self.normalizeDataAlias(original.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(original.lastPathComponent).standardizedFileURL)
            // Never let a Foundation directory hint append a slash to the final
            // symlink: POSIX lstat must inspect the link itself on every OS.
            let canonical = URL(fileURLWithPath: resolved.path, isDirectory: false)
            try checkSafety(canonical, running: running)
            let identity = try Self.identity(at: canonical)
            if let expected = candidate.expectedIdentity, expected != identity { throw CleanupError.changedPath(original.path) }
            unique[canonical.path] = CleanupCandidate(url: canonical, bytes: candidate.bytes, reason: candidate.reason, expectedIdentity: identity)
        }
        var result: [CleanupCandidate] = []
        for candidate in unique.values.sorted(by: { $0.url.path < $1.url.path }) {
            if result.contains(where: { contains($0.url, candidate.url) }) { continue }
            result.append(candidate)
        }
        return result
    }

    func moveToTrash(_ candidates: [CleanupCandidate]) -> CleanupResult {
        let validated: [CleanupCandidate]
        do { validated = try validate(candidates) }
        catch { return CleanupResult(moved: [], failures: [error.localizedDescription]) }
        var moved: [URL] = []
        var failures: [String] = []
        var receipts: [TrashReceipt] = []
        for candidate in validated {
            do {
                // Recheck existence, running applications and symlink ancestors immediately before mutation.
                let checked = try validate([candidate])
                guard let current = checked.first, current.url.path == candidate.url.path else {
                    throw CleanupError.unsafePath(candidate.url.path)
                }
                var resulting: NSURL?
                if let trashOperation { try trashOperation(current.url) }
                else { try fm.trashItem(at: current.url, resultingItemURL: &resulting) }
                moved.append(current.url)
                let trashURL = resulting as URL?
                // Trash names can be reused after an item is removed. Identify
                // its destination so an old receipt cannot restore another file.
                let trashIdentity = trashURL.flatMap { try? Self.identity(at: $0) }
                receipts.append(TrashReceipt(originalURL: current.url, trashURL: trashURL,
                                             bytes: current.bytes, trashIdentity: trashIdentity))
            } catch {
                failures.append("\(candidate.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return CleanupResult(moved: moved, failures: failures, receipts: receipts)
    }

    /// Restore only a recorded Trash destination, never overwrite a new file,
    /// and apply the same protected-location checks used before cleanup.
    func restore(_ receipt: TrashReceipt) throws {
        guard let source = receipt.trashURL, source.isFileURL, receipt.originalURL.isFileURL else {
            throw CleanupError.missingPath("The recorded item is not available in Trash.")
        }
        let canonicalSource = source.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(source.lastPathComponent).standardizedFileURL
        let localTrash = home.appendingPathComponent(".Trash").resolvingSymlinksInPath()
        var allowedTrash = contains(localTrash, canonicalSource) && canonicalSource.path != localTrash.path
        let components = canonicalSource.pathComponents
        if components.count > 5, components[1] == "Volumes", components[3] == ".Trashes", components[4] == String(getuid()) { allowedTrash = true }
        guard allowedTrash else { throw CleanupError.unsafePath(source.path) }
        guard let expected = receipt.trashIdentity else { throw CleanupError.unverifiedTrash(source.path) }
        guard try Self.identity(at: canonicalSource) == expected else { throw CleanupError.changedTrash(source.path) }
        let destination = Self.normalizeDataAlias(receipt.originalURL.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(receipt.originalURL.lastPathComponent).standardizedFileURL)
        try checkSafety(destination, running: runningApplicationURLs().map { Self.normalizeDataAlias($0.resolvingSymlinksInPath()) })
        guard (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey])) == nil else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                          userInfo: [NSLocalizedDescriptionKey: "A new item already exists at \(destination.path). Restore it through Finder to choose another location."])
        }
        try fm.moveItem(at: canonicalSource, to: destination)
    }

    /// lstat intentionally identifies the final link itself, never its target.
    static func identity(at url: URL) throws -> CleanupIdentity {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &metadata) } ?? -1 }
        guard status == 0 else { throw CleanupError.missingPath(url.path) }
        return CleanupIdentity(metadata: metadata)
    }

    private func checkSafety(_ url: URL, running: [URL]) throws {
        let path = url.path
        let blockedTrees = ["/System", "/bin", "/sbin", "/usr", "/private", "/dev", "/Network"]
        guard path != "/", !blockedTrees.contains(where: { contains(URL(fileURLWithPath: $0), url) }) else {
            throw CleanupError.unsafePath(path)
        }
        guard !contains(url, ownApplicationURL), !contains(ownApplicationURL, url) else {
            throw CleanupError.unsafePath(path)
        }
        if running.contains(where: { contains(url, $0) || contains($0, url) }) {
            throw CleanupError.runningApplication(path)
        }

        if contains(URL(fileURLWithPath: "/Volumes"), url) {
            let components = url.pathComponents
            let protectedVolumeNames = [".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems",
                                        "System", "Library", "bin", "sbin", "usr", "private"]
            guard components.count > 3,
                  !protectedVolumeNames.contains(components[3]),
                  allowedRoots.contains(where: { contains($0, url) }) else {
                throw CleanupError.unsafePath(path)
            }
            return
        }

        if contains(home, url) {
            guard path != home.path else { throw CleanupError.unsafePath(path) }
            let protectedRoots = ["Library", "Library/Caches", "Library/Containers", "Library/Group Containers",
                                  "Library/Application Support", "Library/Preferences", "Library/Logs",
                                  "Library/Saved Application State", "Library/Developer", "Applications",
                                  "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"]
            guard !protectedRoots.contains(where: { home.appendingPathComponent($0).path == path }),
                  !contains(home.appendingPathComponent(".Trash"), url) else {
                throw CleanupError.unsafePath(path)
            }
            return
        }

        let applications = URL(fileURLWithPath: "/Applications")
        if contains(applications, url), url.pathExtension.lowercased() == "app" {
            guard !(Bundle(url: url)?.bundleIdentifier?.hasPrefix("com.apple.") ?? false) else {
                throw CleanupError.unsafePath(path)
            }
            return
        }
        for root in ["/Library/Caches", "/Library/Logs", "/Library/Application Support", "/Library/Preferences"] {
            let rootURL = URL(fileURLWithPath: root)
            if url.path != rootURL.path, contains(rootURL, url) { return }
        }
        throw CleanupError.unsafePath(path)
    }

    private func contains(_ parent: URL, _ child: URL) -> Bool {
        child.path == parent.path || child.path.hasPrefix(parent.path == "/" ? "/" : parent.path + "/")
    }

    /// APFS firmlinks are not symbolic links: both paths refer to the same startup data.
    /// Map only known writable namespaces; all other /System paths remain protected.
    private static func normalizeDataAlias(_ url: URL) -> URL {
        let prefix = "/System/Volumes/Data"
        guard url.path.hasPrefix(prefix + "/") else { return url }
        let suffix = String(url.path.dropFirst(prefix.count))
        guard ["/Users", "/Applications", "/Library"].contains(where: {
            suffix == $0 || suffix.hasPrefix($0 + "/")
        }) else { return url }
        return URL(fileURLWithPath: suffix).standardizedFileURL
    }
}
