import Foundation
import Testing
@testable import DiskSense

private final class EmptyInventory: AppInventoryScanning {
    var calls = 0
    func buildInventory(onProgress: @escaping (String) -> Void, completion: @escaping ([AppEntry]) -> Void) { calls += 1; completion([]) }
}
private final class EmptyCleanup: JunkScanning {
    func detect(onProgress: @escaping (String) -> Void, completion: @escaping ([JunkItem], Int) -> Void) { completion([], 0) }
}

@MainActor
struct SavedScanLifecycleTests {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for asynchronous scan state")
    }
    @Test func scanPersistsReopensWithoutRescanAndBrowsesFromIndex() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("Tree")
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(repeating: 1, count: 12000).write(to: nested.appendingPathComponent("sample.bin"))
        let store = try ScanStore(directory: fixture.appendingPathComponent("Store"))
        let first = AppModel(home: root.path, inventory: EmptyInventory(), junkDetector: EmptyCleanup(), store: store)
        first.runFullScan()
        try await wait { !first.isScanning && first.snapshot != nil && !first.largestFiles.isEmpty && FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("inventory.json").path) }
        let snapshot = try #require(first.snapshot)
        let noRescan = EmptyInventory()
        let reopened = AppModel(home: root.path, inventory: noRescan, junkDetector: EmptyCleanup(), store: store)
        reopened.bootstrap()
        try await wait { reopened.showingSavedScan && !reopened.largestFiles.isEmpty }
        #expect(noRescan.calls == 0)
        #expect(reopened.snapshot?.id == snapshot.id)
        #expect(reopened.homeBreakdown.first?.name == "Nested")
        reopened.browse(nested)
        try await wait { !reopened.browserIsScanning }
        #expect(reopened.browserItems.first?.name == "sample.bin")
        reopened.findFiles(text: "sample.bin")
        try await wait { !reopened.isSearching }
        #expect(reopened.searchResults.first?.logicalBytes == 12000)
    }

    @Test func unavailableRootKeepsTheLastCompletedScan() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("Tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(repeating: 1, count: 8192).write(to: root.appendingPathComponent("keep.bin"))
        let store = try ScanStore(directory: fixture.appendingPathComponent("Store"))
        let model = AppModel(home: root.path, inventory: EmptyInventory(), junkDetector: EmptyCleanup(), store: store)
        model.runFullScan()
        try await wait { !model.isScanning && model.snapshot != nil }
        let saved = try #require(model.snapshot)
        try FileManager.default.removeItem(at: root)
        model.runFullScan()
        try await wait { !model.isScanning }
        #expect(model.snapshot?.id == saved.id)
        #expect(model.homeBreakdown.first?.name == "keep.bin")
        #expect(model.showingSavedScan)
        #expect(model.notice?.contains("kept") == true)
        #expect(try store.snapshots().count == 1)
    }

    @Test func rescanRefreshesAnOpenDescendantAndItsCachedContents() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("Tree")
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(repeating: 1, count: 8192).write(to: nested.appendingPathComponent("first.bin"))
        let store = try ScanStore(directory: fixture.appendingPathComponent("Store"))
        let model = AppModel(home: root.path, inventory: EmptyInventory(), junkDetector: EmptyCleanup(), store: store)
        model.runFullScan()
        try await wait { !model.isScanning && model.snapshot != nil }
        let previous = try #require(model.snapshot)
        model.browse(nested)
        try await wait { !model.browserIsScanning }
        #expect(model.browserItems.map(\.name) == ["first.bin"])

        try Data(repeating: 2, count: 16384).write(to: nested.appendingPathComponent("new.bin"))
        model.runFullScan()
        // Both calls occur in the same main-actor turn, before the new scan can
        // publish. Browsing therefore reads the previous completed index.
        model.browse(nested)
        model.selection = .spaceMap
        try await wait { !model.isScanning && model.snapshot?.id != previous.id && !model.browserIsScanning }
        #expect(model.browserURL == ScanStore.canonical(nested))
        #expect(Set(model.browserItems.map(\.name)) == ["first.bin", "new.bin"])
        #expect(model.selection == .spaceMap)

        // Reopening the descendant must also use the fresh cached result.
        model.browse(root)
        model.browse(nested)
        try await wait { !model.browserIsScanning }
        #expect(Set(model.browserItems.map(\.name)) == ["first.bin", "new.bin"])
    }
}
