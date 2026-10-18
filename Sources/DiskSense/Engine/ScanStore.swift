import Foundation
import SQLite3
import Darwin

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
struct StoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SQLConnection {
    let handle: OpaquePointer
    init(url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open scan database."
            if let pointer { sqlite3_close(pointer) }
            throw StoreError(message: message)
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 10_000)
        try execute("PRAGMA foreign_keys=ON;")
    }
    deinit { sqlite3_close(handle) }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    func statement(_ sql: String) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        return pointer
    }
    func bind(_ values: [String], to statement: OpaquePointer, startingAt: Int32 = 1) {
        for (offset, value) in values.enumerated() { sqlite3_bind_text(statement, startingAt + Int32(offset), value, -1, sqliteTransient) }
    }
    func failure() -> StoreError { StoreError(message: String(cString: sqlite3_errmsg(handle))) }
    func run(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    /// A failed read must not look like an empty or partially successful result.
    func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure()
        }
    }
    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}

/// WAL permits instant read-only browsing of the last completed scan while a new
/// scan is written. Each background operation owns its SQLite connection.
final class ScanStore: @unchecked Sendable {
    let maximumEntries: Int
    let databaseURL: URL
    let directory: URL
    init(directory: URL, maximumEntries: Int = 150_000) throws {
        self.maximumEntries = max(1, maximumEntries)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        databaseURL = directory.appendingPathComponent("scans.sqlite")
        let isNew = !FileManager.default.fileExists(atPath: databaseURL.path)
        let db = try SQLConnection(url: databaseURL)
        try db.execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA journal_size_limit=8388608;
        PRAGMA wal_autocheckpoint=256;
        CREATE TABLE IF NOT EXISTS snapshots(id TEXT PRIMARY KEY,root TEXT NOT NULL,started REAL,finished REAL,bytes INTEGER,entry_count INTEGER,unreadable INTEGER);
        CREATE TABLE IF NOT EXISTS entries(scan TEXT NOT NULL,path TEXT NOT NULL,parent TEXT NOT NULL,name TEXT,is_dir INTEGER,is_package INTEGER,bytes INTEGER,logical INTEGER,modified REAL,unreadable INTEGER,category TEXT,is_link INTEGER,PRIMARY KEY(scan,path));
        CREATE INDEX IF NOT EXISTS children_idx ON entries(scan,parent,bytes DESC);
        CREATE INDEX IF NOT EXISTS largest_idx ON entries(scan,is_dir,bytes DESC);
        CREATE TABLE IF NOT EXISTS history(id TEXT PRIMARY KEY,date REAL,payload BLOB);
        CREATE TABLE IF NOT EXISTS pending_scans(id TEXT PRIMARY KEY,pid INTEGER,started REAL);
        """)
        if isNew { try db.execute("PRAGMA user_version=4") }
        let columns = try db.statement("PRAGMA table_info(snapshots)")
        var hasCoverage = false
        while try db.step(columns) { if SQLConnection.text(columns, 1) == "index_truncated" { hasCoverage = true } }
        sqlite3_finalize(columns)
        if !hasCoverage { try db.execute("ALTER TABLE snapshots ADD COLUMN index_truncated INTEGER NOT NULL DEFAULT 0") }
        let abandoned = try db.statement("SELECT id,pid FROM pending_scans")
        defer { sqlite3_finalize(abandoned) }
        var dead: [String] = []
        while try db.step(abandoned) {
            let pid = pid_t(sqlite3_column_int(abandoned, 1))
            if pid > 0 && kill(pid, 0) == -1 && errno == ESRCH { dead.append(SQLConnection.text(abandoned, 0)) }
        }
        for id in dead {
            let cleanup = try db.statement("DELETE FROM entries WHERE scan=?")
            db.bind([id], to: cleanup); try db.run(cleanup); sqlite3_finalize(cleanup)
            let pending = try db.statement("DELETE FROM pending_scans WHERE id=?")
            db.bind([id], to: pending); try db.run(pending); sqlite3_finalize(pending)
        }
    }
    static func canonical(_ url: URL) -> URL {
        if url.path == "/" { return url }
        let parent = url.deletingLastPathComponent()
        guard let resolved = realpath(parent.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(url.lastPathComponent)
    }
    static func live() throws -> ScanStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try ScanStore(directory: support.appendingPathComponent("DiskSense", isDirectory: true))
    }
    func begin(root: URL) throws -> ScanWriter { try ScanWriter(store: self, root: root) }
    func snapshots(root: String? = nil) throws -> [ScanSnapshot] {
        let db = try SQLConnection(url: databaseURL)
        let s = try db.statement("SELECT id,root,started,finished,bytes,entry_count,unreadable,index_truncated FROM snapshots \(root == nil ? "" : "WHERE root=?") ORDER BY finished DESC LIMIT 30")
        defer { sqlite3_finalize(s) }
        if let root { db.bind([Self.canonical(URL(fileURLWithPath: root)).path], to: s) }
        var result: [ScanSnapshot] = []
        while try db.step(s) {
            result.append(ScanSnapshot(id: SQLConnection.text(s, 0), root: SQLConnection.text(s, 1), started: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)), finished: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)), bytes: sqlite3_column_int64(s, 4), entryCount: Int(sqlite3_column_int64(s, 5)), unreadable: Int(sqlite3_column_int64(s, 6)), indexTruncated: sqlite3_column_int(s, 7) != 0))
        }
        return result
    }
    private var columns: String { "path,parent,name,is_dir,is_package,bytes,logical,modified,unreadable,category,is_link" }
    private func entry(_ s: OpaquePointer) -> CatalogEntry {
        CatalogEntry(path: SQLConnection.text(s, 0), parent: SQLConnection.text(s, 1), name: SQLConnection.text(s, 2), isDirectory: sqlite3_column_int(s, 3) != 0, isPackage: sqlite3_column_int(s, 4) != 0, bytes: sqlite3_column_int64(s, 5), logicalBytes: sqlite3_column_int64(s, 6), modified: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)), unreadable: Int(sqlite3_column_int(s, 8)), category: StorageCategory(rawValue: SQLConnection.text(s, 9)) ?? .other, isSymbolicLink: sqlite3_column_int(s, 10) != 0)
    }
    func children(snapshot: String, parent: String) throws -> [CatalogEntry] {
        let db = try SQLConnection(url: databaseURL)
        let s = try db.statement("SELECT \(columns) FROM entries WHERE scan=? AND parent=? AND path<>? ORDER BY bytes DESC,name LIMIT 10000")
        defer { sqlite3_finalize(s) }; let path = Self.canonical(URL(fileURLWithPath: parent)).path; db.bind([snapshot, path, path], to: s)
        var result: [CatalogEntry] = []
        while try db.step(s) { result.append(entry(s)) }
        return result
    }
    func search(snapshot: String, text: String = "", minimumBytes: Int64 = 0, category: StorageCategory? = nil, filesOnly: Bool = true, olderThan: Date? = nil) throws -> [CatalogEntry] {
        let db = try SQLConnection(url: databaseURL)
        var sql = "SELECT \(columns) FROM entries WHERE scan=? AND bytes>=?"
        if filesOnly { sql += " AND is_dir=0" }
        if !text.isEmpty { sql += " AND instr(lower(path),lower(?))>0" }
        if category != nil { sql += " AND category=?" }
        if olderThan != nil { sql += " AND modified<?" }
        sql += " AND path<>(SELECT root FROM snapshots WHERE id=?) ORDER BY bytes DESC,path LIMIT 200"
        let s = try db.statement(sql); defer { sqlite3_finalize(s) }
        db.bind([snapshot], to: s); sqlite3_bind_int64(s, 2, minimumBytes)
        var column: Int32 = 3
        if !text.isEmpty { db.bind([text], to: s, startingAt: column); column += 1 }
        if let category { db.bind([category.rawValue], to: s, startingAt: column); column += 1 }
        if let olderThan { sqlite3_bind_double(s, column, olderThan.timeIntervalSince1970); column += 1 }
        db.bind([snapshot], to: s, startingAt: column)
        var result: [CatalogEntry] = []
        while try db.step(s) { result.append(entry(s)) }
        return result
    }
    func categories(snapshot: String) throws -> [CategoryTotal] {
        let db = try SQLConnection(url: databaseURL)
        let s = try db.statement("SELECT category,SUM(bytes) FROM entries WHERE scan=? AND is_dir=0 GROUP BY category ORDER BY SUM(bytes) DESC")
        defer { sqlite3_finalize(s) }; db.bind([snapshot], to: s)
        var result: [CategoryTotal] = []
        while try db.step(s) { result.append(CategoryTotal(category: StorageCategory(rawValue: SQLConnection.text(s, 0)) ?? .other, bytes: sqlite3_column_int64(s, 1))) }
        return result
    }
    func changes(current: ScanSnapshot, previous: ScanSnapshot) throws -> [ScanChange] {
        guard current.root == previous.root else { return [] }
        let before = try children(snapshot: previous.id, parent: previous.root)
        let after = try children(snapshot: current.id, parent: current.root)
        let b = Dictionary(uniqueKeysWithValues: before.map { ($0.path, $0.bytes) })
        let a = Dictionary(uniqueKeysWithValues: after.map { ($0.path, $0.bytes) })
        return Set(b.keys).union(a.keys).map { ScanChange(path: $0, before: b[$0] ?? 0, after: a[$0] ?? 0) }
            .filter { $0.delta != 0 }.sorted { abs($0.delta) > abs($1.delta) }
    }
    func localDataBytes() -> Int64 {
        ["scans.sqlite", "scans.sqlite-wal", "scans.sqlite-shm", "inventory.json"].reduce(0) { sum, name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return sum + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
    /// Include all potentially matching size buckets, independent of the
    /// intentionally limited interactive search results.
    func duplicateCandidates(snapshot: String) throws -> [CatalogEntry] {
        let db = try SQLConnection(url: databaseURL)
        let s = try db.statement("""
        SELECT \(columns) FROM entries
        WHERE scan=? AND is_dir=0 AND is_link=0 AND unreadable=0
          AND category<>'Applications' AND logical>=1048576
          AND logical IN (SELECT logical FROM entries WHERE scan=? AND is_dir=0 AND is_link=0 AND unreadable=0 AND category<>'Applications' AND logical>=1048576 GROUP BY logical HAVING COUNT(*)>1)
        ORDER BY logical DESC,path
        """)
        defer { sqlite3_finalize(s) }
        db.bind([snapshot, snapshot], to: s)
        var result: [CatalogEntry] = []
        while try db.step(s) { result.append(entry(s)) }
        return result
    }
    /// Only cached indexes are pruned. Cleanup receipts and inventory survive.
    /// Run off the main thread; compaction can take time for legacy large files.
    func maintain() throws {
        let db = try SQLConnection(url: databaseURL)
        let version = try db.statement("PRAGMA user_version")
        let schemaVersion = try db.step(version) ? sqlite3_column_int(version, 0) : 0
        sqlite3_finalize(version)
        if schemaVersion < 4 {
            // Old whole-disk indexes counted filesystem aliases. They cannot
            // be repaired reliably; retain user files, inventory and receipts.
            try db.execute("DELETE FROM entries; DELETE FROM snapshots; DELETE FROM pending_scans; PRAGMA user_version=4;")
        }
        let saved = try snapshots()
        for snapshot in saved where snapshot.entryCount > maximumEntries + 10_001 {
            let trim = try db.statement("DELETE FROM entries WHERE scan=? AND path<>? AND parent<>? AND path NOT IN (SELECT path FROM entries WHERE scan=? ORDER BY is_dir DESC,bytes DESC LIMIT ?)")
            db.bind([snapshot.id, snapshot.root, snapshot.root, snapshot.id, String(maximumEntries)], to: trim)
            try db.run(trim); sqlite3_finalize(trim)
            let mark = try db.statement("UPDATE snapshots SET index_truncated=1,entry_count=(SELECT COUNT(*) FROM entries WHERE scan=?) WHERE id=?")
            db.bind([snapshot.id, snapshot.id], to: mark); try db.run(mark); sqlite3_finalize(mark)
        }
        try db.execute("BEGIN IMMEDIATE; DELETE FROM entries WHERE scan IN (SELECT id FROM snapshots ORDER BY finished DESC LIMIT -1 OFFSET 4); DELETE FROM snapshots WHERE id NOT IN (SELECT id FROM snapshots ORDER BY finished DESC LIMIT 4); COMMIT;")
        // Evict older cached scans when live SQLite pages exceed the budget.
        // A current over-budget index is reduced, never presented as complete.
        func usedBytes() throws -> Int64 {
            func pragma(_ name: String) throws -> Int64 {
                let s = try db.statement("PRAGMA " + name); defer { sqlite3_finalize(s) }
                return try db.step(s) ? sqlite3_column_int64(s, 0) : 0
            }
            return try (pragma("page_count") - pragma("freelist_count")) * pragma("page_size")
        }
        let budget: Int64 = 256 * 1024 * 1024
        var retained = try snapshots()
        while try usedBytes() > budget, retained.count > 1 {
            let old = retained.removeLast()
            let remove = try db.statement("DELETE FROM entries WHERE scan=?")
            db.bind([old.id], to: remove); try db.run(remove); sqlite3_finalize(remove)
            let header = try db.statement("DELETE FROM snapshots WHERE id=?")
            db.bind([old.id], to: header); try db.run(header); sqlite3_finalize(header)
        }
        if let current = retained.first {
            var limit = maximumEntries / 2
            while try usedBytes() > budget, limit >= 1000 {
                let trim = try db.statement("DELETE FROM entries WHERE scan=? AND path<>? AND parent<>? AND path NOT IN (SELECT path FROM entries WHERE scan=? ORDER BY is_dir DESC,bytes DESC LIMIT ?)")
                db.bind([current.id, current.root, current.root, current.id, String(limit)], to: trim); try db.run(trim); sqlite3_finalize(trim)
                let mark = try db.statement("UPDATE snapshots SET index_truncated=1,entry_count=(SELECT COUNT(*) FROM entries WHERE scan=?) WHERE id=?")
                db.bind([current.id, current.id], to: mark); try db.run(mark); sqlite3_finalize(mark)
                limit /= 2
            }
        }
        let pages = try db.statement("PRAGMA freelist_count")
        let freePages = try db.step(pages) ? sqlite3_column_int64(pages, 0) : 0
        sqlite3_finalize(pages)
        if freePages > 4096 { try db.execute("VACUUM") }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    func clearScans() throws {
        let db = try SQLConnection(url: databaseURL)
        try db.execute("DELETE FROM entries; DELETE FROM snapshots; DELETE FROM pending_scans; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")
    }
    func saveInventory(apps: [AppEntry], junk: [JunkItem]) throws {
        try JSONEncoder().encode(SavedInventory(date: Date(), apps: apps, junk: junk)).write(to: directory.appendingPathComponent("inventory.json"), options: .atomic)
    }
    func inventory() throws -> SavedInventory? {
        let url = directory.appendingPathComponent("inventory.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(SavedInventory.self, from: Data(contentsOf: url))
    }
    func saveHistory(_ event: CleanupEvent) throws {
        let payload = try JSONEncoder().encode(event)
        let db = try SQLConnection(url: databaseURL)
        let s = try db.statement("INSERT OR REPLACE INTO history VALUES(?,?,?)"); defer { sqlite3_finalize(s) }
        db.bind([event.id], to: s); sqlite3_bind_double(s, 2, event.date.timeIntervalSince1970)
        _ = payload.withUnsafeBytes { sqlite3_bind_blob(s, 3, $0.baseAddress, Int32($0.count), sqliteTransient) }
        try db.run(s)
    }
    func history() throws -> [CleanupEvent] {
        let db = try SQLConnection(url: databaseURL)
        let s = try db.statement("SELECT payload FROM history ORDER BY date DESC LIMIT 100"); defer { sqlite3_finalize(s) }
        var result: [CleanupEvent] = []
        while try db.step(s) {
            if let bytes = sqlite3_column_blob(s, 0), let event = try? JSONDecoder().decode(CleanupEvent.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, 0)))) { result.append(event) }
        }
        return result
    }
}

/// A prepared insert and short transactions keep the full index on disk rather
/// than retaining millions of observable Swift objects in memory.
final class ScanWriter {
    let id = UUID().uuidString
    let root: URL
    let excludedPath: String
    let started = Date()
    private let db: SQLConnection
    private let insert: OpaquePointer
    private(set) var count = 0
    private(set) var failure: Error?
    private var closed = false
    private let maximumEntries: Int
    private let store: ScanStore
    private var essentialCount = 0
    private var indexedTextBytes = 0
    private(set) var indexTruncated = false
    init(store: ScanStore, root: URL) throws {
        self.store = store
        self.maximumEntries = store.maximumEntries
        self.root = ScanStore.canonical(root)
        self.excludedPath = ScanStore.canonical(store.directory).path
        db = try SQLConnection(url: store.databaseURL)
        insert = try db.statement("INSERT OR REPLACE INTO entries VALUES(?,?,?,?,?,?,?,?,?,?,?,?)")
        try db.execute("BEGIN IMMEDIATE")
        let pending = try db.statement("INSERT INTO pending_scans VALUES(?,?,?)")
        db.bind([id], to: pending); sqlite3_bind_int(pending, 2, getpid()); sqlite3_bind_double(pending, 3, started.timeIntervalSince1970)
        try db.run(pending); sqlite3_finalize(pending)
    }
    deinit {
        sqlite3_finalize(insert)
        if !closed { discard() }
    }
    func excludes(_ path: String) -> Bool { path == excludedPath || path.hasPrefix(excludedPath + "/") }
    func record(_ entry: CatalogEntry) {
        guard failure == nil, !closed else { return }
        let essential = entry.path == root.path || entry.parent == root.path
        if essential && essentialCount >= 10_000 && entry.path != root.path { indexTruncated = true; return }
        if essential { essentialCount += 1 }
        if (count >= maximumEntries || indexedTextBytes >= 32 * 1024 * 1024) && !essential {
            indexTruncated = true; return
        }
        indexedTextBytes += entry.path.utf8.count + entry.parent.utf8.count + entry.name.utf8.count
        sqlite3_reset(insert); sqlite3_clear_bindings(insert)
        db.bind([id, entry.path, entry.parent, entry.name], to: insert)
        sqlite3_bind_int(insert, 5, entry.isDirectory ? 1 : 0)
        sqlite3_bind_int(insert, 6, entry.isPackage ? 1 : 0)
        sqlite3_bind_int64(insert, 7, entry.bytes); sqlite3_bind_int64(insert, 8, entry.logicalBytes)
        sqlite3_bind_double(insert, 9, entry.modified.timeIntervalSince1970)
        sqlite3_bind_int(insert, 10, Int32(entry.unreadable)); db.bind([entry.category.rawValue], to: insert, startingAt: 11)
        sqlite3_bind_int(insert, 12, entry.isSymbolicLink ? 1 : 0)
        do {
            try db.run(insert); count += 1
            if count % 2000 == 0 { try db.execute("COMMIT; BEGIN IMMEDIATE") }
        } catch { failure = error }
    }
    func complete(bytes: Int64, unreadable: Int) throws -> ScanSnapshot {
        if let failure { throw failure }
        let snapshot = ScanSnapshot(id: id, root: root.path, started: started, finished: Date(), bytes: bytes, entryCount: count, unreadable: unreadable, indexTruncated: indexTruncated)
        let s = try db.statement("INSERT INTO snapshots VALUES(?,?,?,?,?,?,?,?)"); defer { sqlite3_finalize(s) }
        db.bind([id, root.path], to: s); sqlite3_bind_double(s, 3, started.timeIntervalSince1970); sqlite3_bind_double(s, 4, snapshot.finished.timeIntervalSince1970)
        sqlite3_bind_int64(s, 5, bytes); sqlite3_bind_int64(s, 6, Int64(count)); sqlite3_bind_int64(s, 7, Int64(unreadable))
        sqlite3_bind_int(s, 8, indexTruncated ? 1 : 0)
        try db.run(s)
        let pending = try db.statement("DELETE FROM pending_scans WHERE id=?")
        db.bind([id], to: pending); try db.run(pending); sqlite3_finalize(pending)
        try db.execute("COMMIT"); closed = true
        // Keep the latest two completed scans per root; cancelled scans never
        // become selectable. Remove orphaned partial rows at the same time.
        let prune = try db.statement("DELETE FROM entries WHERE scan IN (SELECT id FROM snapshots WHERE root=? ORDER BY finished DESC LIMIT -1 OFFSET 2)")
        db.bind([root.path], to: prune); try db.run(prune); sqlite3_finalize(prune)
        let pruneSnapshots = try db.statement("DELETE FROM snapshots WHERE root=? AND id NOT IN (SELECT id FROM snapshots WHERE root=? ORDER BY finished DESC LIMIT 2)")
        db.bind([root.path, root.path], to: pruneSnapshots); try db.run(pruneSnapshots); sqlite3_finalize(pruneSnapshots)
        try? store.maintain()
        return (try? store.snapshots(root: root.path).first) ?? snapshot
    }
    func discard() {
        guard !closed else { return }
        try? db.execute("ROLLBACK")
        if let s = try? db.statement("DELETE FROM entries WHERE scan=?") { db.bind([id], to: s); try? db.run(s); sqlite3_finalize(s) }
        if let s = try? db.statement("DELETE FROM pending_scans WHERE id=?") { db.bind([id], to: s); try? db.run(s); sqlite3_finalize(s) }
        closed = true
    }
}
