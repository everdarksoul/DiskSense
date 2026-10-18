import Foundation
import Testing
@testable import DiskSense

private final class InventoryStub: AppInventoryScanning {
    var progress: [(String) -> Void] = []
    var completions: [([AppEntry]) -> Void] = []

    func buildInventory(onProgress: @escaping (String) -> Void,
                        completion: @escaping ([AppEntry]) -> Void) {
        progress.append(onProgress)
        completions.append(completion)
    }
}

private final class JunkStub: JunkScanning {
    var progress: [(String) -> Void] = []
    var completions: [([JunkItem], Int) -> Void] = []

    func detect(onProgress: @escaping (String) -> Void,
                completion: @escaping ([JunkItem], Int) -> Void) {
        progress.append(onProgress)
        completions.append(completion)
    }
}

@MainActor
struct ScanCompletionTests {
    // Drain queued progress callbacks in the same FIFO order as the app.
    private func drainProgress() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitForFolders(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if model.completedStages.contains("Folders") { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Folder scan did not finish")
    }

    @Test func testBothCompletionOrdersAndLateProgress() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        for junkFinishesFirst in [true, false] {
            let inventory = InventoryStub()
            let junk = JunkStub()
            let model = AppModel(home: home.path, inventory: inventory, junkDetector: junk)
            model.runFullScan()
            try await waitForFolders(model)
            #expect(model.rootTree?.children != nil)

            if junkFinishesFirst {
                junk.completions[0]([], 3)
                inventory.progress[0]("Still indexing")
            } else {
                inventory.completions[0]([])
                junk.progress[0]("Still measuring")
            }
            await drainProgress()
            guard case .scanning = model.phase else {
                Issue.record("Must wait for the remaining engine")
                continue
            }

            if junkFinishesFirst {
                inventory.completions[0]([])
            } else {
                junk.completions[0]([], 3)
            }
            #expect(model.phase == .ready)
            #expect(model.overview.unreadableCount == 3)

            inventory.progress[0]("Late inventory update")
            junk.progress[0]("Late junk update")
            await drainProgress()
            #expect(model.phase == .ready)
        }
    }

    @Test func testOverlappingRescanAndCallbacksFromPreviousScan() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let inventory = InventoryStub()
        let junk = JunkStub()
        let model = AppModel(home: home.path, inventory: inventory, junkDetector: junk)

        model.runFullScan()
        try await waitForFolders(model)
        model.runFullScan()
        #expect(inventory.completions.count == 1)
        #expect(junk.completions.count == 1)
        junk.completions[0]([], 1)
        junk.progress[0]("Progress from completed engine")
        inventory.progress[0]("Inventory still running")
        await drainProgress()
        #expect(model.phase == .scanning("Inventory still running"))
        inventory.completions[0]([])

        model.runFullScan()
        try await waitForFolders(model)
        inventory.progress[1]("New scan")
        await drainProgress()
        inventory.progress[0]("Old scan")
        junk.completions[0]([], 99)
        inventory.completions[0]([])
        await drainProgress()
        #expect(model.phase == .scanning("New scan"))
        #expect(model.overview.unreadableCount == 0)

        inventory.completions[1]([])
        junk.completions[1]([], 2)
        #expect(model.phase == .ready)
        #expect(model.overview.unreadableCount == 2)
    }
    @Test func browserKeepsErrorsOnCachedVisitsAndUsesStableRowIdentity() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let model = AppModel(home: home.path, inventory: InventoryStub(), junkDetector: JunkStub())
        let missing = home.appendingPathComponent("missing")
        model.browse(missing)
        for _ in 0..<500 {
            if !model.browserIsScanning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model.browserUnreadable == 1)
        model.browse(missing)
        #expect(model.browserUnreadable == 1)
        let first = ScanItem(url: home, name: "Test", isDirectory: true, isPackage: false, depth: 0)
        let replacement = ScanItem(url: home, name: "Test", isDirectory: true, isPackage: false, depth: 0)
        #expect(first.id == replacement.id)
    }

}
