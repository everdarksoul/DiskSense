import Foundation
import Testing
@testable import DiskSense

struct InventoryAndCleanupTests {
    @Test func relatedMatchesRequireBundleBoundaryOrWholeName() {
        #expect(AppInventory.matches(filename: "com.example.Code.plist", bundleID: "com.example.Code", appName: "Code"))
        #expect(AppInventory.matches(filename: "com.example.Code.savedState", bundleID: "com.example.Code", appName: "Code"))
        #expect(AppInventory.matches(filename: "Code", bundleID: "com.example.Code", appName: "Code"))
        #expect(!AppInventory.matches(filename: "Xcode", bundleID: "com.example.Code", appName: "Code"))
        #expect(!AppInventory.matches(filename: "com.example.Codec.plist", bundleID: "com.example.Code", appName: "Code"))
        #expect(!AppInventory.matches(filename: "My Code Projects", bundleID: "com.example.Code", appName: "Code"))
    }

    @Test func inventoryMeasuresEntireBundlesAndRelatedData() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let root = home.appendingPathComponent("Applications")
        let app = root.appendingPathComponent("Utilities/Fixture.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleName": "Fixture", "CFBundleIdentifier": "com.test.fixture"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data(repeating: 42, count: 100_000).write(to: resources.appendingPathComponent(".hidden"))
        let support = home.appendingPathComponent("Library/Application Support/com.test.fixture")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(repeating: 73, count: 75_000).write(to: support.appendingPathComponent("database"))
        let unrelated = home.appendingPathComponent("Library/Application Support/AnotherFixtureApp")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let engine = AppInventory(home: home, appRoots: [root, root])
        let apps: [AppEntry] = await withCheckedContinuation { continuation in
            engine.buildInventory(onProgress: { _ in
                #expect(Thread.isMainThread)
            }, completion: { entries in
                #expect(Thread.isMainThread)
                continuation.resume(returning: entries)
            })
        }
        #expect(apps.count == 1)
        let fixture = try #require(apps.first)
        #expect(fixture.name == "Fixture")
        #expect(fixture.allocatedBytes == DiskScanner().measure(at: app).bytes)
        #expect(fixture.allocatedBytes > 0)
        #expect(fixture.relatedFiles.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path } == [support.resolvingSymlinksInPath().path])
        #expect(fixture.relatedBytes == DiskScanner().measure(at: support).bytes)
    }

    @MainActor
    @Test func cancellationSuppressesOldCallbacksAndAllowsRescan() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let inventory = AppInventory(home: home, appRoots: [home])
        let junk = JunkDetector(home: home)
        var obsoleteCallbacks = 0
        inventory.buildInventory(onProgress: { _ in obsoleteCallbacks += 1 },
                                 completion: { _ in obsoleteCallbacks += 1 })
        junk.detect(onProgress: { _ in obsoleteCallbacks += 1 },
                    completion: { _, _ in obsoleteCallbacks += 1 })
        inventory.cancel()
        junk.cancel()
        await withCheckedContinuation { continuation in
            inventory.buildInventory(onProgress: { _ in }, completion: { _ in continuation.resume() })
        }
        await withCheckedContinuation { continuation in
            junk.detect(onProgress: { _ in }, completion: { _, _ in continuation.resume() })
        }
        #expect(obsoleteCallbacks == 0)
    }

    @Test func cleanupCandidatesAreDisjointAndExcludeValuableAppData() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let included = ["Library/Caches/Homebrew", "Library/Caches/pip", ".npm/_cacache", "Library/Developer/Xcode/DerivedData"]
        let excluded = [".Trash", "Library/Containers/com.some.oldapp", "Library/Developer/CoreSimulator", "Library/Logs"]
        for path in included + excluded {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(repeating: 97, count: 20_000).write(to: url.appendingPathComponent(".payload"))
        }
        // A cache symlink to app data must not produce another cleanup target.
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/linkedData"),
                                  withDestinationURL: home.appendingPathComponent("Library/Containers/com.some.oldapp"))
        let engine = JunkDetector(home: home)
        let items: [JunkItem] = await withCheckedContinuation { continuation in
            engine.detect(onProgress: { _ in #expect(Thread.isMainThread) }, completion: { items, _ in
                #expect(Thread.isMainThread)
                continuation.resume(returning: items)
            })
        }
        #expect(Set(items.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }) == Set(included.map { home.appendingPathComponent($0).resolvingSymlinksInPath().path }))
        for item in items {
            #expect(item.bytes == DiskScanner().measure(at: URL(fileURLWithPath: item.path)).bytes)
            #expect(!items.contains { $0.path != item.path && $0.path.hasPrefix(item.path + "/") })
        }
    }
}
