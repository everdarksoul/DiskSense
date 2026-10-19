import Foundation
import Testing
import SQLite3
@testable import DiskSense

struct ScanStoreTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func completedScanReopensWithNestedSizesSearchAndCategories() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Tree")
        let deep = root.appendingPathComponent("Projects/Sample.app/Contents")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let file = deep.appendingPathComponent("hidden.dat")
        try Data(repeating: 42, count: 123456).write(to: file)
        let store = try ScanStore(directory: home.appendingPathComponent("Store"))
        let writer = try store.begin(root: root)
        let result = DiskScanner().scanDirectory(at: root, catalog: writer)
        let saved = try writer.complete(bytes: result.bytes, unreadable: result.unreadable)
        let reopened = try ScanStore(directory: home.appendingPathComponent("Store"))
        #expect(try reopened.snapshots(root: root.path).first?.id == saved.id)
        let children = try reopened.children(snapshot: saved.id, parent: root.appendingPathComponent("Projects").path)
        #expect(children.count == 1)
        #expect(children.first?.bytes == DiskScanner().measure(at: root.appendingPathComponent("Projects/Sample.app")).bytes)
        #expect(try reopened.search(snapshot: saved.id, text: "hidden.dat").first?.logicalBytes == 123456)
        #expect(try reopened.search(snapshot: saved.id, text: "' OR 1=1 --").isEmpty == true)
        #expect(try reopened.categories(snapshot: saved.id).contains { $0.category == .applications })
    }
    @Test func twoScansProduceChangesAndRetainOnlyTwoSnapshots() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try ScanStore(directory: home.appendingPathComponent("Store"))
        func scan() throws -> ScanSnapshot {
            let writer = try store.begin(root: root)
            let result = DiskScanner().scanDirectory(at: root, catalog: writer)
            return try writer.complete(bytes: result.bytes, unreadable: result.unreadable)
        }
        let before = try scan()
        try Data(repeating: 99, count: 50000).write(to: root.appendingPathComponent("new.bin"))
        let after = try scan()
        let changes = try store.changes(current: after, previous: before)
        #expect(changes.count == 1)
        #expect(changes.first?.before == 0)
        #expect((changes.first?.delta ?? 0) > 0)
        _ = try scan()
        #expect(try store.snapshots(root: root.path).count == 2)
    }
    @Test func cancellationDoesNotReplaceCompletedSnapshotAndHistoryRoundTrips() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let store = try ScanStore(directory: home.appendingPathComponent("Store"))
        let writer = try store.begin(root: home)
        writer.record(CatalogEntry(path: home.appendingPathComponent("x").path, parent: home.path, name: "x", isDirectory: false, isPackage: false, bytes: 123, logicalBytes: 123, modified: Date(), unreadable: 0, category: .other, isSymbolicLink: false))
        writer.discard()
        #expect(try store.snapshots().isEmpty == true)
        let receipt = TrashReceipt(originalURL: home.appendingPathComponent("x"), trashURL: home.appendingPathComponent(".Trash/x"), bytes: 123)
        let event = CleanupEvent(id: UUID().uuidString, date: Date(), receipts: [receipt], failures: ["An example failure"], restored: [])
        try store.saveHistory(event)
        #expect(try store.history().first?.receipts == [receipt])
        #expect(try store.history().first?.failures == ["An example failure"])
    }
    @Test func batchedPartialIndexIsDiscardedAndClearingScansKeepsHistory() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let store = try ScanStore(directory: home.appendingPathComponent("Store"))
        let writer = try store.begin(root: home)
        for index in 0..<2501 {
            writer.record(CatalogEntry(path: home.appendingPathComponent("item-\(index)").path, parent: home.path, name: "item-\(index)", isDirectory: false, isPackage: false, bytes: Int64(index), logicalBytes: Int64(index), modified: Date(), unreadable: 0, category: .other, isSymbolicLink: false))
        }
        writer.discard()
        #expect(try store.snapshots().isEmpty == true)
        try store.saveHistory(CleanupEvent(id: "test", date: Date(), receipts: [], failures: ["Example failure"], restored: []))
        try store.clearScans()
        #expect(try store.history().count == 1)
    }

    @Test func interruptedReadThrowsRatherThanReportingAnEmptyResult() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let db = try SQLConnection(url: home.appendingPathComponent("read-test.sqlite"))
        let statement = try db.statement("WITH RECURSIVE numbers(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM numbers WHERE value<100) SELECT SUM(value) FROM numbers")
        defer { sqlite3_finalize(statement) }
        // Use SQLite's supported interruption hook, without corrupting a file
        // or depending on a particular filesystem permission configuration.
        sqlite3_progress_handler(db.handle, 1, { _ in 1 }, nil)
        defer { sqlite3_progress_handler(db.handle, 0, nil, nil) }
        #expect(throws: StoreError.self) { _ = try db.step(statement) }
    }

    @Test func versionedIndexRetiresLegacyCacheOnlyAfterCopyingReceipts() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("scans.sqlite")
        let event = CleanupEvent(id: "legacy-event", date: Date(), receipts: [], failures: ["Preserve this receipt"], restored: [])
        do {
            let old = try SQLConnection(url: legacy)
            try old.execute("CREATE TABLE history(id TEXT PRIMARY KEY,date REAL,payload BLOB); CREATE TABLE pending_scans(id TEXT,pid INTEGER);")
            let statement = try old.statement("INSERT INTO history VALUES(?,?,?)")
            defer { sqlite3_finalize(statement) }
            old.bind([event.id], to: statement); sqlite3_bind_double(statement, 2, event.date.timeIntervalSince1970)
            let payload = try JSONEncoder().encode(event)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            try old.run(statement)
        }
        let store = try ScanStore(directory: directory)
        #expect(store.databaseURL.lastPathComponent == "scans-v4.sqlite")
        try store.maintain()
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try store.history().first?.failures == event.failures)
        try store.maintain()
        #expect(try store.history().count == 1)
    }

    @Test func unreadableLegacyReceiptKeepsTheOriginalCache() throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("scans.sqlite")
        do {
            let old = try SQLConnection(url: legacy)
            try old.execute("CREATE TABLE history(payload BLOB); INSERT INTO history VALUES('bad JSON');")
        }
        let store = try ScanStore(directory: directory)
        #expect(throws: (any Error).self) { try store.maintain() }
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test func permanentHistoryRoundTripsAndLegacyHistoryKeepsTrashSemantics() throws {
        let home = try fixture(); defer { try? FileManager.default.removeItem(at: home) }
        let store = try ScanStore(directory: home.appendingPathComponent("Store"))
        let receipt = TrashReceipt(originalURL: home.appendingPathComponent("gone"), trashURL: nil, bytes: 12)
        let permanent = CleanupEvent(id: "permanent", date: Date(), receipts: [receipt], failures: [], restored: [], disposition: .permanent)
        try store.saveHistory(permanent)
        #expect(try store.history().first?.disposition == .permanent)
        #expect(try store.history().first?.receipts.first?.trashURL == nil)
        let legacy = CleanupEvent(id: "legacy", date: Date(), receipts: [], failures: [], restored: [])
        let encoded = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("disposition"))
        #expect(try JSONDecoder().decode(CleanupEvent.self, from: encoded).disposition == nil)
    }

}
