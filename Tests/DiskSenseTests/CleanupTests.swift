import Foundation
import Testing
@testable import DiskSense

struct CleanupTests {
    private func withFixture(_ body: (URL) throws -> Void) throws {
        // Keep fixtures outside /private, which the production policy deliberately protects.
        let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    private func candidate(_ url: URL) -> CleanupCandidate {
        CleanupCandidate(url: url, bytes: 42, reason: "Selected in test")
    }

    private func service(_ home: URL, running: @escaping () -> [URL] = { [] },
                         trash: @escaping CleanupService.TrashOperation = { _ in }) -> CleanupService {
        CleanupService(homeDirectory: home,
                       ownApplicationURL: URL(fileURLWithPath: "/Applications/DiskSense.app"),
                       runningApplicationURLs: running, trashOperation: trash)
    }

    @Test func protectedRootsAndSystemTreesAreRejected() throws {
        try withFixture { home in
            let cleaner = service(home)
            let paths = ["/", "/System/Applications/Chess.app", "/usr/local", "/private/var/log",
                         "/Library", "/Library/Caches", "/Library/LaunchDaemons/example.plist",
                         "/Library/PrivilegedHelperTools/helper", "/Applications",
                         "/Applications/DiskSense.app", home.path,
                         home.appendingPathComponent("Library").path,
                         home.appendingPathComponent("Library/Containers").path,
                         home.appendingPathComponent("Library/Caches").path,
                         home.appendingPathComponent("Library/Application Support").path,
                         home.appendingPathComponent("Downloads").path]
            for path in paths {
                #expect(throws: CleanupError.self) {
                    try cleaner.validate([candidate(URL(fileURLWithPath: path))])
                }
            }
        }
    }

    @Test func explicitCacheChildrenAreAllowedAndNestedSelectionsAreDeduplicated() throws {
        try withFixture { home in
            let cache = home.appendingPathComponent("Library/Caches/example")
            let file = cache.appendingPathComponent("entry")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: file)
            let result = try service(home).validate([candidate(file), candidate(cache), candidate(cache)])
            #expect(result.count == 1)
            #expect(result.first?.url.path == cache.resolvingSymlinksInPath().path)
        }
    }

    @Test func symlinkAncestorsCannotRedirectCleanupIntoSystemLocations() throws {
        try withFixture { home in
            let alias = home.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/System"))
            #expect(throws: CleanupError.self) {
                try service(home).validate([candidate(alias.appendingPathComponent("Applications"))])
            }
        }
    }

    @Test func finalSymlinkIsTrashedWithoutDeletingItsTarget() throws {
        try withFixture { home in
            let alias = home.appendingPathComponent("system-link")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/System"))
            var operations: [URL] = []
            let result = service(home, trash: { operations.append($0) }).moveToTrash([candidate(alias)])
            #expect(result.failures.isEmpty)
            #expect(operations == [alias])
            #expect(FileManager.default.fileExists(atPath: "/System"))
        }
    }

    @Test func missingItemsNeverReachTrashOperation() throws {
        try withFixture { home in
            var operations = 0
            let result = service(home, trash: { _ in operations += 1 })
                .moveToTrash([candidate(home.appendingPathComponent("missing"))])
            #expect(result.moved.isEmpty)
            #expect(result.failures.count == 1)
            #expect(operations == 0)
        }
    }

    @Test func trashFailuresAreReportedWithoutClaimingSuccess() throws {
        try withFixture { home in
            let file = home.appendingPathComponent("selected.txt")
            try Data("test".utf8).write(to: file)
            let result = service(home, trash: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }).moveToTrash([candidate(file)])
            #expect(result.moved.isEmpty)
            #expect(result.failures.count == 1)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func runningApplicationsAreRejectedAndRecheckedBeforeCleanup() throws {
        try withFixture { home in
            let app = home.appendingPathComponent("Example.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            #expect(throws: CleanupError.self) {
                try service(home, running: { [app] }).validate([candidate(app)])
            }
            var checks = 0
            var operations = 0
            let cleaner = service(home, running: {
                checks += 1
                return checks > 1 ? [app] : []
            }, trash: { _ in operations += 1 })
            let result = cleaner.moveToTrash([candidate(app)])
            #expect(result.moved.isEmpty)
            #expect(result.failures.count == 1)
            #expect(operations == 0)
        }
    }

    @Test func similarlyNamedSiblingDoesNotGetCollapsedWithSelectedFolder() throws {
        try withFixture { home in
            let folder = home.appendingPathComponent("cache")
            let sibling = home.appendingPathComponent("cache-backup")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            #expect(try service(home).validate([candidate(folder), candidate(sibling)]).count == 2)
        }
    }

    @Test func dataVolumeAliasMapsToTheSameHomeSelection() throws {
        try withFixture { home in
            let file = home.appendingPathComponent("selected.txt")
            try Data("test".utf8).write(to: file)
            let alias = URL(fileURLWithPath: "/System/Volumes/Data" + file.path)
            let result = try service(home).validate([candidate(alias), candidate(file)])
            #expect(result.count == 1)
            #expect(result.first?.url.path == file.path)
        }
    }

    @Test func externalVolumesRequireAnExplicitScopeAndProtectVolumeRoots() throws {
        try withFixture { home in
            let volume = URL(fileURLWithPath: "/Volumes/DiskSense-Test-\(UUID().uuidString)")
            let file = volume.appendingPathComponent("selected.txt")
            let scoped = CleanupService(homeDirectory: home, allowedRoots: [volume],
                                        runningApplicationURLs: { [] }, trashOperation: { _ in })
            do {
                _ = try scoped.validate([candidate(file)])
                Issue.record("A missing fixture must report its absence")
            } catch CleanupError.missingPath { /* Scope accepted; no real volume is changed. */ }
            do {
                _ = try service(home).validate([candidate(file)])
                Issue.record("An external volume must require an explicit scan scope")
            } catch CleanupError.unsafePath { }
            for protected in [volume, volume.appendingPathComponent(".Trashes/entry"),
                              volume.appendingPathComponent("System/Library")] {
                do {
                    _ = try scoped.validate([candidate(protected)])
                    Issue.record("Volume roots and system metadata must remain protected")
                } catch CleanupError.unsafePath { }
            }
        }
    }
    @Test func restoreReturnsRecordedTrashItemAndNeverOverwritesANewFile() throws {
        try withFixture { home in
            let original = home.appendingPathComponent("Downloads/restore.bin")
            let trash = home.appendingPathComponent(".Trash/restore.bin")
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old data".utf8).write(to: trash)
            let receipt = TrashReceipt(originalURL: original, trashURL: trash, bytes: 8,
                                       trashIdentity: try CleanupService.identity(at: trash))
            try service(home).restore(receipt)
            #expect(try Data(contentsOf: original) == Data("old data".utf8))
            #expect(!FileManager.default.fileExists(atPath: trash.path))
            try Data("another item".utf8).write(to: trash)
            let nextReceipt = TrashReceipt(originalURL: original, trashURL: trash, bytes: 12,
                                           trashIdentity: try CleanupService.identity(at: trash))
            #expect(throws: (any Error).self) { try service(home).restore(nextReceipt) }
            #expect(try Data(contentsOf: original) == Data("old data".utf8))
            #expect(FileManager.default.fileExists(atPath: trash.path))
        }
    }

    @Test func restoreRejectsUntrustedSourcesAndProtectedDestinations() throws {
        try withFixture { home in
            let fake = home.appendingPathComponent("fake-trash.bin")
            try Data("data".utf8).write(to: fake)
            #expect(throws: CleanupError.self) {
                try service(home).restore(TrashReceipt(originalURL: home.appendingPathComponent("restored.bin"), trashURL: fake, bytes: 4,
                                                       trashIdentity: try CleanupService.identity(at: fake)))
            }
            let trash = home.appendingPathComponent(".Trash/file")
            try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("data".utf8).write(to: trash)
            #expect(throws: CleanupError.self) {
                try service(home).restore(TrashReceipt(originalURL: URL(fileURLWithPath: "/System/restore.bin"), trashURL: trash, bytes: 4,
                                                       trashIdentity: try CleanupService.identity(at: trash)))
            }
        }
    }

    @Test func replacedFileIsRejectedAfterReview() throws {
        try withFixture { home in
            let url = home.appendingPathComponent("reviewed.bin")
            try Data("old".utf8).write(to: url)
            var operations = 0
            let cleaner = service(home, trash: { _ in operations += 1 })
            let reviewed = try cleaner.validate([candidate(url)])
            let replacement = home.appendingPathComponent("replacement.bin")
            try Data("new".utf8).write(to: replacement)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: replacement, to: url)
            let result = cleaner.moveToTrash(reviewed)
            #expect(result.moved.isEmpty)
            #expect(result.failures.count == 1)
            #expect(operations == 0)
            #expect(try Data(contentsOf: url) == Data("new".utf8))
        }
    }

    @Test func restoreRejectsAnUnrelatedFileThatReusesATrashPath() throws {
        try withFixture { home in
            let original = home.appendingPathComponent("Downloads/old.bin")
            let trash = home.appendingPathComponent(".Trash/old.bin")
            let replacement = home.appendingPathComponent("replacement.bin")
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: trash)
            let receipt = TrashReceipt(originalURL: original, trashURL: trash, bytes: 3,
                                       trashIdentity: try CleanupService.identity(at: trash))
            try Data("unrelated".utf8).write(to: replacement)
            try FileManager.default.removeItem(at: trash)
            try FileManager.default.moveItem(at: replacement, to: trash)
            do {
                try service(home).restore(receipt)
                Issue.record("A reused Trash path must not restore the replacement file")
            } catch CleanupError.changedTrash { }
            #expect(!FileManager.default.fileExists(atPath: original.path))
            #expect(try Data(contentsOf: trash) == Data("unrelated".utf8))
        }
    }

    @Test func fileChangedInPlaceIsRejectedAfterReview() throws {
        try withFixture { home in
            let file = home.appendingPathComponent("reviewed.bin")
            try Data("old".utf8).write(to: file)
            var operations = 0
            let cleaner = service(home, trash: { _ in operations += 1 })
            let reviewed = try cleaner.validate([candidate(file)])
            let before = try CleanupService.identity(at: file)
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(" changed".utf8))
            try handle.close()
            let after = try CleanupService.identity(at: file)
            #expect(before.inode == after.inode)
            let result = cleaner.moveToTrash(reviewed)
            #expect(result.moved.isEmpty)
            #expect(result.failures.count == 1)
            #expect(operations == 0)
            #expect(try Data(contentsOf: file) == Data("old changed".utf8))
        }
    }

    @Test func legacyReceiptDecodesButRequiresFinderToRestore() throws {
        try withFixture { home in
            let original = home.appendingPathComponent("restored.bin")
            let trash = home.appendingPathComponent(".Trash/old.bin")
            try FileManager.default.createDirectory(at: trash.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("data".utf8).write(to: trash)
            let data = try JSONEncoder().encode(TrashReceipt(originalURL: original, trashURL: trash, bytes: 4))
            #expect(String(decoding: data, as: UTF8.self).contains("trashIdentity") == false)
            let legacy = try JSONDecoder().decode(TrashReceipt.self, from: data)
            #expect(legacy.trashIdentity == nil)
            do {
                try service(home).restore(legacy)
                Issue.record("An old receipt without an identity must require Finder")
            } catch CleanupError.unverifiedTrash { }
            #expect(!FileManager.default.fileExists(atPath: original.path))
            #expect(try Data(contentsOf: trash) == Data("data".utf8))
        }
    }

    @Test func permanentRemovalDeletesOnlyTheReviewedFixture() throws {
        try withFixture { home in
            let selected = home.appendingPathComponent("delete.txt")
            let keeper = home.appendingPathComponent("keep.txt")
            try Data("remove".utf8).write(to: selected)
            try Data("keep".utf8).write(to: keeper)
            let cleaner = CleanupService(homeDirectory: home, ownApplicationURL: URL(fileURLWithPath: "/Applications/Fake.app"), runningApplicationURLs: { [] })
            let reviewed = try cleaner.validate([candidate(selected)])
            let result = cleaner.deletePermanently(reviewed)
            #expect(result.failures.isEmpty && result.moved.count == 1)
            #expect(!FileManager.default.fileExists(atPath: selected.path))
            #expect(FileManager.default.fileExists(atPath: keeper.path))
            #expect(result.receipts.first?.trashURL == nil)
        }
    }
    @Test func permanentRemovalRejectsStaleIdentityAndProtectedRoots() throws {
        try withFixture { home in
            let selected = home.appendingPathComponent("changed.txt")
            try Data("before".utf8).write(to: selected)
            let cleaner = service(home)
            let reviewed = try cleaner.validate([candidate(selected)])
            try FileManager.default.removeItem(at: selected)
            try Data("replacement".utf8).write(to: selected)
            #expect(cleaner.deletePermanently(reviewed).moved.isEmpty)
            #expect(cleaner.deletePermanently([candidate(home)]).moved.isEmpty)
            #expect(FileManager.default.fileExists(atPath: selected.path))
        }
    }
    @Test func permanentRemovalOfFinalLinkPreservesItsTarget() throws {
        try withFixture { home in
            let target = home.appendingPathComponent("keep.txt")
            let link = home.appendingPathComponent("link")
            try Data("keep".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let cleaner = CleanupService(homeDirectory: home, ownApplicationURL: URL(fileURLWithPath: "/Applications/Fake.app"), runningApplicationURLs: { [] })
            let reviewed = try cleaner.validate([candidate(link)])
            #expect(cleaner.deletePermanently(reviewed).failures.isEmpty)
            #expect(FileManager.default.fileExists(atPath: target.path))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        }
    }
    @Test func associatedRunningAppBlocksOnlyItsConnectedCleanup() throws {
        try withFixture { home in
            let cache = home.appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let app = URL(fileURLWithPath: "/Applications/Associated.app")
            let other = URL(fileURLWithPath: "/Applications/Other.app")
            let cleaner = CleanupService(homeDirectory: home, runningApplicationURLs: { [app, other] }, associatedApplicationURL: app)
            #expect(throws: CleanupError.self) { try cleaner.validate([candidate(cache)]) }
            let allowed = CleanupService(homeDirectory: home, runningApplicationURLs: { [other] }, associatedApplicationURL: app)
            #expect(try allowed.validate([candidate(cache)]).count == 1)
        }
    }

    @Test func permanentFailureIsReportedAndNeverCreatesASuccessReceipt() throws {
        try withFixture { home in
            let selected = home.appendingPathComponent("permission-denied.txt")
            try Data("keep".utf8).write(to: selected)
            let cleaner = CleanupService(homeDirectory: home, runningApplicationURLs: { [] }, deleteOperation: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            })
            let result = cleaner.deletePermanently(try cleaner.validate([candidate(selected)]))
            #expect(result.moved.isEmpty && result.receipts.isEmpty)
            #expect(result.failures.count == 1)
            #expect(result.failures.first?.contains("Finder") == true)
            #expect(try Data(contentsOf: selected) == Data("keep".utf8))
        }
    }
    @Test func associatedAppRelaunchAfterReviewBlocksRemoval() throws {
        try withFixture { home in
            let file = home.appendingPathComponent("cache.txt")
            try Data("keep".utf8).write(to: file)
            let app = URL(fileURLWithPath: "/Applications/Associated.app")
            var running: [URL] = []
            let cleaner = CleanupService(homeDirectory: home, runningApplicationURLs: { running }, associatedApplicationURL: app)
            let reviewed = try cleaner.validate([candidate(file)])
            running = [app]
            #expect(cleaner.deletePermanently(reviewed).moved.isEmpty)
            #expect(cleaner.moveToTrash(reviewed).moved.isEmpty)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

}
