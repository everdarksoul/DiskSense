import Foundation
import Testing
@testable import DiskSense

private final class CountingInventory: AppInventoryScanning {
    var calls = 0
    func buildInventory(onProgress: @escaping (String) -> Void, completion: @escaping ([AppEntry]) -> Void) { calls += 1; completion([]) }
}
private final class CountingJunk: JunkScanning {
    var calls = 0
    func detect(onProgress: @escaping (String) -> Void, completion: @escaping ([JunkItem], Int) -> Void) { calls += 1; completion([], 0) }
}
@MainActor
struct NavigationTests {
    private func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        Issue.record("Navigation did not complete")
    }
    @Test func mapExploresBeforeIndexAndCachesRepeatVisits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = root.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 8192).write(to: child.appendingPathComponent("x"))
        let model = AppModel(home: root.path, inventory: CountingInventory(), junkDetector: CountingJunk())
        model.selection = .spaceMap
        model.loadMap(child)
        try await wait { !model.mapLoading }
        #expect(model.selection == .spaceMap)
        #expect(model.mapEntries.first?.name == "x")
        let tile = try #require(model.mapEntries.first)
        model.mapSelected = tile
        model.loadMap(child)
        #expect(!model.mapLoading)
        #expect(model.mapSelected?.path == tile.path)
        model.loadMap(root)
        try await wait { !model.mapLoading }
        model.goBack()
        #expect(model.mapURL == ScanStore.canonical(child))
        #expect(!model.mapLoading)
        model.goForward()
        #expect(model.mapURL == ScanStore.canonical(root))
    }
    @Test func folderRefreshDoesNotRerunInventoriesAndSavedRootSwitchStaysInMap() async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("Tree")
        let other = fixture.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let inventory = CountingInventory(), junk = CountingJunk()
        let store = try ScanStore(directory: fixture.appendingPathComponent("Store"))
        let model = AppModel(home: root.path, inventory: inventory, junkDetector: junk, store: store)
        model.runFullScan()
        try await wait { !model.isScanning && model.snapshot != nil }
        model.refreshFolder()
        try await wait { !model.isScanning }
        #expect(inventory.calls == 1 && junk.calls == 1)
        let saved = try #require(model.snapshot)
        model.selection = .spaceMap
        model.selectRoot(other)
        try await wait { !model.isBootstrapping && !model.isScanning && model.scanRoot == ScanStore.canonical(other) }
        #expect(model.selection == .spaceMap)
        #expect(inventory.calls == 1 && junk.calls == 1)
        model.selectRoot(root)
        try await wait { !model.isBootstrapping && model.snapshot?.id == saved.id }
        #expect(model.showingSavedScan)
        #expect(model.selection == .spaceMap)
    }
    @Test func boundedIndexKeepsMeasuredRootAndMarksPartialSearchCoverage() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = fixture.appendingPathComponent("Tree/Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for n in 0..<20 { try Data(repeating: 1, count: 8192).write(to: nested.appendingPathComponent("\(n).bin")) }
        let store = try ScanStore(directory: fixture.appendingPathComponent("Store"), maximumEntries: 3)
        let root = nested.deletingLastPathComponent()
        let writer = try store.begin(root: root)
        let result = DiskScanner().scanDirectory(at: root, catalog: writer)
        let saved = try writer.complete(bytes: result.bytes, unreadable: result.unreadable)
        #expect(saved.indexTruncated == true)
        #expect(saved.entryCount <= 5)
        #expect(saved.bytes == result.bytes)
        #expect(try store.children(snapshot: saved.id, parent: root.path).first?.bytes == result.children.first?.bytes)
    }
}
