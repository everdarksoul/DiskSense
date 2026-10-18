import Foundation
import Testing
import Darwin
@testable import DiskSense

struct DuplicateFinderTests {
    private let size = 1_024 * 1_024

    private func fixture(_ body: (URL) throws -> Void) throws {
        let proposed = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSense-Duplicates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        let root = ScanStore.canonical(proposed)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ url: URL, byte: UInt8 = 0x41, count: Int? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: byte, count: count ?? size).write(to: url)
    }

    private func entry(_ url: URL, symbolicLink: Bool = false) throws -> CatalogEntry {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return CatalogEntry(path: url.path, parent: url.deletingLastPathComponent().path, name: url.lastPathComponent,
            isDirectory: false, isPackage: false, bytes: Int64(value.st_blocks) * 512,
            logicalBytes: Int64(value.st_size), modified: Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec)),
            unreadable: 0, category: .other, isSymbolicLink: symbolicLink)
    }

    @Test func hashesContentsRatherThanNamesOrEqualSizes() throws {
        try fixture { root in
            let a = root.appendingPathComponent("original.dat")
            let b = root.appendingPathComponent("renamed-copy.bin")
            let different = root.appendingPathComponent("same-size.bin")
            let smallA = root.appendingPathComponent("small-a")
            let smallB = root.appendingPathComponent("small-b")
            try write(a); try write(b); try write(different, byte: 0x42)
            try write(smallA, count: 100); try write(smallB, count: 100)
            let entries = try [a, b, different, smallA, smallB].map { try entry($0) }
            let result = DuplicateFinder.find(entries: entries)
            #expect(!result.cancelled)
            #expect(result.skipped == 0)
            #expect(result.groups.count == 1)
            #expect(Set(result.groups.first?.entries.map(\.path) ?? []) == Set([a.path, b.path]))
            #expect(result.groups.first?.bytesPerCopy == Int64(size))
            #expect(result.groups.first?.reclaimableBytes == entries[1].bytes)
        }
    }

    @Test func hardLinksNeverInflateRecoverableStorage() throws {
        try fixture { root in
            let original = root.appendingPathComponent("a")
            let alias = root.appendingPathComponent("b")
            let copy = root.appendingPathComponent("c")
            try write(original); try FileManager.default.linkItem(at: original, to: alias); try write(copy)
            let result = DuplicateFinder.find(entries: try [original, alias, copy].map { try entry($0) })
            #expect(result.groups.isEmpty)
            #expect(result.skipped == 2)
        }
    }

    @Test func rejectsFinalSymlinkEvenWhenCatalogMetadataClaimsAFile() throws {
        try fixture { root in
            let original = root.appendingPathComponent("original")
            let link = root.appendingPathComponent("link")
            try write(original)
            let originalEntry = try entry(original)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
            let staleLinkEntry = CatalogEntry(path: link.path, parent: root.path, name: "link", isDirectory: false,
                isPackage: false, bytes: originalEntry.bytes, logicalBytes: originalEntry.logicalBytes,
                modified: originalEntry.modified, unreadable: 0, category: .other, isSymbolicLink: false)
            let result = DuplicateFinder.find(entries: [originalEntry, staleLinkEntry])
            #expect(result.groups.isEmpty)
            #expect(result.skipped == 1)
        }
    }

    @Test func rejectsAnAncestorReplacedWithASymlink() throws {
        try fixture { root in
            let folder = root.appendingPathComponent("inside")
            let outside = root.appendingPathComponent("outside")
            let original = root.appendingPathComponent("original")
            let candidate = folder.appendingPathComponent("copy")
            try write(original); try write(candidate); try write(outside.appendingPathComponent("copy"))
            let entries = try [original, candidate].map { try entry($0) }
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
            let result = DuplicateFinder.find(entries: entries)
            #expect(result.groups.isEmpty)
            #expect(result.skipped == 1)
        }
    }

    @Test func skipsStaleCatalogSizeAndFilesChangedWhileHashing() throws {
        try fixture { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            try write(a); try write(b)
            let entries = try [a, b].map { try entry($0) }
            try write(b, count: size + 1)
            let stale = DuplicateFinder.find(entries: entries)
            #expect(stale.groups.isEmpty)
            #expect(stale.skipped == 1)
            try write(b)
            let fresh = try [a, b].map { try entry($0) }
            var changed = false
            let duringRead = DuplicateFinder.find(entries: fresh, onProgress: { path in
                guard !changed else { return }; changed = true
                // The callback runs after descriptor metadata was captured.
                try? Data(repeating: 0x43, count: size).write(to: URL(fileURLWithPath: path))
            })
            #expect(changed)
            #expect(duringRead.groups.isEmpty)
            #expect(duringRead.skipped >= 1)
        }
    }

    @Test func cancellationDuringStreamingDiscardsPartialGroups() throws {
        try fixture { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            try write(a, count: size * 3); try write(b, count: size * 3)
            let entries = try [a, b].map { try entry($0) }
            let immediate = DuplicateFinder.find(entries: entries, isCancelled: { true })
            #expect(immediate.cancelled)
            #expect(immediate.groups.isEmpty)
            var stopped = false
            let result = DuplicateFinder.find(entries: entries, isCancelled: { stopped }, onProgress: { _ in stopped = true })
            #expect(result.cancelled)
            #expect(result.groups.isEmpty)
        }
    }

    @Test func duplicateInputRecordsAreNotAdditionalCopies() throws {
        try fixture { root in
            let a = root.appendingPathComponent("a")
            try write(a)
            let candidate = try entry(a)
            let result = DuplicateFinder.find(entries: [candidate, candidate])
            #expect(result.groups.isEmpty)
            #expect(result.skipped == 1)
        }
    }

    @Test func skipsManagedPackageAndLibraryContents() throws {
        try fixture { root in
            let names = ["Example.app", "Pictures.photoslibrary", "Old.photolibrary", "Music.musiclibrary", "Thing.framework", "Thing.bundle", ".git"]
            let ordinary = root.appendingPathComponent("ordinary")
            try write(ordinary)
            var entries = [try entry(ordinary)]
            for name in names {
                let file = root.appendingPathComponent(name).appendingPathComponent("content")
                try write(file); entries.append(try entry(file))
            }
            let result = DuplicateFinder.find(entries: entries)
            #expect(result.groups.isEmpty)
            #expect(result.skipped == names.count)
        }
    }

    @Test func cleanupValidationRequiresAnUnselectedUnchangedOriginal() throws {
        try fixture { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            try write(a); try write(b)
            let entries = try [a, b].map { try entry($0) }
            let groups = DuplicateFinder.find(entries: entries).groups
            #expect(groups.count == 1)
            let candidates = try DuplicateFinder.validateForCleanup(entries: [entries[1]], groups: groups)
            #expect(candidates.count == 1)
            #expect(candidates.first?.url == b)
            #expect(candidates.first?.expectedIdentity == groups.first?.fingerprints[b.path])
            #expect(throws: DuplicateCleanupError.self) {
                _ = try DuplicateFinder.validateForCleanup(entries: entries, groups: groups)
            }
            try FileManager.default.removeItem(at: a)
            #expect(throws: DuplicateCleanupError.self) {
                _ = try DuplicateFinder.validateForCleanup(entries: [entries[1]], groups: groups)
            }
        }
    }

    @Test func cleanupValidationRejectsInPlaceEditsAfterHashing() throws {
        try fixture { root in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            try write(a); try write(b)
            let entries = try [a, b].map { try entry($0) }
            let groups = DuplicateFinder.find(entries: entries).groups
            #expect(groups.count == 1)
            try write(b, byte: 0x42)
            #expect(throws: DuplicateCleanupError.self) {
                _ = try DuplicateFinder.validateForCleanup(entries: [entries[1]], groups: groups)
            }
        }
    }
}
