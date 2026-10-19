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
    init(url: URL, readOnly: Bool = false) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
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
    let maximumEntries: Int?
    private let historyBudgetBytes: Int64
    let databaseURL: URL
    let directory: URL
    init(directory: URL, maximumEntries: Int? = nil, historyBudgetBytes: Int64 = 256 * 1024 * 1024) throws {
        self.maximumEntries = maximumEntries.map { max(1, $0) }
        self.historyBudgetBytes = max(0, historyBudgetBytes)
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        databaseURL = directory.appendingPathComponent("scans-v5.sqlite")
        let isNew = !FileManager.default.fileExists(atPath: databaseURL.path)
        let db = try SQLConnection(url: databaseURL)
        try db.execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA journal_size_limit=8388608;
        PRAGMA wal_autocheckpoint=256;
        CREATE TABLE IF NOT EXISTS snapshots(id TEXT PRIMARY KEY,root TEXT NOT NULL,started REAL,finished REAL,bytes INTEGER,entry_count INTEGER,unreadable INTEGER);
        CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT);
        CREATE TABLE IF NOT EXISTS catalog_scans(key INTEGER PRIMARY KEY,uuid TEXT NOT NULL UNIQUE);
        CREATE TABLE IF NOT EXISTS directories(id INTEGER PRIMARY KEY,scan INTEGER NOT NULL REFERENCES catalog_scans(key) ON DELETE CASCADE,path TEXT NOT NULL,UNIQUE(scan,path));
        CREATE TABLE IF NOT EXISTS entries(scan INTEGER NOT NULL REFERENCES catalog_scans(key) ON DELETE CASCADE,parent INTEGER NOT NULL REFERENCES directories(id) ON DELETE CASCADE,name TEXT NOT NULL,is_dir INTEGER,is_package INTEGER,bytes INTEGER,logical INTEGER,modified REAL,unreadable INTEGER,category TEXT,is_link INTEGER,PRIMARY KEY(parent,name));
        CREATE INDEX IF NOT EXISTS children_idx ON entries(parent,bytes DESC);
        CREATE INDEX IF NOT EXISTS largest_idx ON entries(scan,is_dir,bytes DESC);
        CREATE TABLE IF NOT EXISTS history(id TEXT PRIMARY KEY,date REAL,payload BLOB);
        CREATE TABLE IF NOT EXISTS pending_scans(id TEXT PRIMARY KEY,pid INTEGER,started REAL);
        """)
        if isNew { try db.execute("PRAGMA user_version=5") }
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
            let cleanup = try db.statement("DELETE FROM catalog_scans WHERE uuid=?")
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
    func preferredRebuildRoot() throws -> URL? {
        let db = try SQLConnection(url: databaseURL)
        let s = try db.statement("SELECT value FROM metadata WHERE key='rebuild_root'")
        defer { sqlite3_finalize(s) }
        guard try db.step(s) else { return nil }
        let path = SQLConnection.text(s, 0)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
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
    private var filePath: String { "CASE WHEN e.name='/' AND d.path='/' THEN '/' WHEN d.path='/' THEN '/'||e.name ELSE d.path||'/'||e.name END" }
    private var columns: String { "\(filePath),d.path,e.name,e.is_dir,e.is_package,e.bytes,e.logical,e.modified,e.unreadable,e.category,e.is_link" }
    private var joinedEntries: String { "entries e JOIN directories d ON d.id=e.parent" }
    private func scanKey(_ snapshot: String, db: SQLConnection) throws -> Int64? {
        let s = try db.statement("SELECT key FROM catalog_scans WHERE uuid=?")
        defer { sqlite3_finalize(s) }; db.bind([snapshot], to: s)
        return try db.step(s) ? sqlite3_column_int64(s, 0) : nil
    }
    private func entry(_ s: OpaquePointer) -> CatalogEntry {
        CatalogEntry(path: SQLConnection.text(s, 0), parent: SQLConnection.text(s, 1), name: SQLConnection.text(s, 2), isDirectory: sqlite3_column_int(s, 3) != 0, isPackage: sqlite3_column_int(s, 4) != 0, bytes: sqlite3_column_int64(s, 5), logicalBytes: sqlite3_column_int64(s, 6), modified: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)), unreadable: Int(sqlite3_column_int(s, 8)), category: StorageCategory(rawValue: SQLConnection.text(s, 9)) ?? .other, isSymbolicLink: sqlite3_column_int(s, 10) != 0)
    }
    func children(snapshot: String, parent: String) throws -> [CatalogEntry] {
        let db = try SQLConnection(url: databaseURL)
        guard let key = try scanKey(snapshot, db: db) else { return [] }
        let s = try db.statement("SELECT \(columns) FROM \(joinedEntries) WHERE d.scan=? AND d.path=? AND (\(filePath))<>? ORDER BY e.bytes DESC,e.name")
        defer { sqlite3_finalize(s) }
        let path = Self.canonical(URL(fileURLWithPath: parent)).path
        sqlite3_bind_int64(s, 1, key); db.bind([path, path], to: s, startingAt: 2)
        var result: [CatalogEntry] = []
        while try db.step(s) { result.append(entry(s)) }
        return result
    }
    func search(snapshot: String, text: String = "", minimumBytes: Int64 = 0, category: StorageCategory? = nil, filesOnly: Bool = true, olderThan: Date? = nil) throws -> [CatalogEntry] {
        let db = try SQLConnection(url: databaseURL)
        guard let key = try scanKey(snapshot, db: db) else { return [] }
        var sql = "SELECT \(columns) FROM \(joinedEntries) WHERE e.scan=? AND e.bytes>=?"
        if filesOnly { sql += " AND e.is_dir=0" }
        if !text.isEmpty { sql += " AND instr(lower(\(filePath)),lower(?))>0" }
        if category != nil { sql += " AND e.category=?" }
        if olderThan != nil { sql += " AND e.modified<?" }
        sql += " AND (\(filePath))<>(SELECT root FROM snapshots WHERE id=?) ORDER BY e.bytes DESC,e.name,e.parent LIMIT 200"
        let s = try db.statement(sql); defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, key); sqlite3_bind_int64(s, 2, minimumBytes)
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
        guard let key = try scanKey(snapshot, db: db) else { return [] }
        let s = try db.statement("SELECT category,SUM(bytes) FROM entries WHERE scan=? AND is_dir=0 GROUP BY category ORDER BY SUM(bytes) DESC")
        defer { sqlite3_finalize(s) }; sqlite3_bind_int64(s, 1, key)
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
        ["scans-v5.sqlite", "scans-v5.sqlite-wal", "scans-v5.sqlite-shm", "scans-v4.sqlite", "scans-v4.sqlite-wal", "scans-v4.sqlite-shm", "scans.sqlite", "scans.sqlite-wal", "scans.sqlite-shm", "inventory.json"].reduce(0) { sum, name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            return sum + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
    /// Include all potentially matching size buckets, independent of the
    /// intentionally limited interactive search results.
    func duplicateCandidates(snapshot: String) throws -> [CatalogEntry] {
        let db = try SQLConnection(url: databaseURL)
        guard let key = try scanKey(snapshot, db: db) else { return [] }
        let s = try db.statement("""
        SELECT \(columns) FROM \(joinedEntries)
        WHERE e.scan=? AND e.is_dir=0 AND e.is_link=0 AND e.unreadable=0
          AND e.category<>'Applications' AND e.logical>=1048576
          AND e.logical IN (SELECT logical FROM entries WHERE scan=? AND is_dir=0 AND is_link=0 AND unreadable=0 AND category<>'Applications' AND logical>=1048576 GROUP BY logical HAVING COUNT(*)>1)
        ORDER BY e.logical DESC,e.name,e.parent
        """)
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, key); sqlite3_bind_int64(s, 2, key)
        var result: [CatalogEntry] = []
        while try db.step(s) { result.append(entry(s)) }
        return result
    }
    /// Versioned index files avoid a multi-gigabyte DELETE/VACUUM migration.
    /// Copy all receipts successfully before retiring the obsolete file.
    private func retireLegacyIndex(named name: String) throws {
        let legacy = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        var events: [CleanupEvent] = []
        var rebuildRoot: String?
        do {
            let old = try SQLConnection(url: legacy, readOnly: true)
            if let pending = try? old.statement("SELECT pid FROM pending_scans") {
                defer { sqlite3_finalize(pending) }
                while try old.step(pending) {
                    let pid = pid_t(sqlite3_column_int(pending, 0))
                    if pid > 0 && kill(pid, 0) == 0 { return }
                }
            }
            if name == "scans-v4.sqlite", let rootQuery = try? old.statement("SELECT root FROM snapshots ORDER BY finished DESC LIMIT 1") {
                defer { sqlite3_finalize(rootQuery) }
                if try old.step(rootQuery) { rebuildRoot = SQLConnection.text(rootQuery, 0) }
            }
            let receipts = try old.statement("SELECT payload FROM history")
            defer { sqlite3_finalize(receipts) }
            while try old.step(receipts) {
                guard let bytes = sqlite3_column_blob(receipts, 0) else { throw StoreError(message: "Legacy cleanup receipt is unreadable; old data was kept.") }
                events.append(try JSONDecoder().decode(CleanupEvent.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(receipts, 0)))))
            }
        }
        let db = try SQLConnection(url: databaseURL)
        let insert = try db.statement("INSERT OR IGNORE INTO history VALUES(?,?,?)")
        defer { sqlite3_finalize(insert) }
        for event in events {
            let payload = try JSONEncoder().encode(event)
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            db.bind([event.id], to: insert); sqlite3_bind_double(insert, 2, event.date.timeIntervalSince1970)
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(insert, 3, $0.baseAddress, Int32($0.count), sqliteTransient) }
            try db.run(insert)
        }
        if let rebuildRoot {
            let hint = try db.statement("INSERT OR REPLACE INTO metadata VALUES('rebuild_root',?)")
            db.bind([rebuildRoot], to: hint); try db.run(hint); sqlite3_finalize(hint)
        }
        // Checkpoint imported receipts before unlinking the obsolete index.
        try db.execute("PRAGMA wal_checkpoint(FULL)")
        try FileManager.default.removeItem(at: legacy)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: legacy.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
    }
    /// Only cached indexes are pruned. Cleanup receipts and inventory survive.
    /// Run off the main thread; compaction can take time for legacy large files.
    func maintain() throws {
        try retireLegacyIndex(named: "scans.sqlite")
        try retireLegacyIndex(named: "scans-v4.sqlite")
        let db = try SQLConnection(url: databaseURL)
        try db.execute("""
        BEGIN IMMEDIATE;
        DELETE FROM catalog_scans WHERE uuid IN (SELECT id FROM snapshots ORDER BY finished DESC LIMIT -1 OFFSET 4);
        DELETE FROM snapshots WHERE id NOT IN (SELECT id FROM snapshots ORDER BY finished DESC LIMIT 4);
        COMMIT;
        """)
        // The budget governs retained history, never completeness of the newest
        // scan. Directory paths are shared instead of repeated for every file.
        func usedBytes() throws -> Int64 {
            func pragma(_ name: String) throws -> Int64 {
                let s = try db.statement("PRAGMA " + name); defer { sqlite3_finalize(s) }
                return try db.step(s) ? sqlite3_column_int64(s, 0) : 0
            }
            return try (pragma("page_count") - pragma("freelist_count")) * pragma("page_size")
        }
        var retained = try snapshots()
        while try usedBytes() > historyBudgetBytes, retained.count > 1 {
            let old = retained.removeLast()
            let remove = try db.statement("DELETE FROM catalog_scans WHERE uuid=?")
            db.bind([old.id], to: remove); try db.run(remove); sqlite3_finalize(remove)
            let header = try db.statement("DELETE FROM snapshots WHERE id=?")
            db.bind([old.id], to: header); try db.run(header); sqlite3_finalize(header)
        }
        let pages = try db.statement("PRAGMA freelist_count")
        let freePages = try db.step(pages) ? sqlite3_column_int64(pages, 0) : 0
        sqlite3_finalize(pages)
        if freePages > 4096 { try db.execute("VACUUM") }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
    func clearScans() throws {
        let db = try SQLConnection(url: databaseURL)
        try db.execute("DELETE FROM catalog_scans; DELETE FROM snapshots; DELETE FROM pending_scans; VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")
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
    private let maximumEntries: Int?
    private let store: ScanStore
    private let key: Int64
    private let findDirectory: OpaquePointer
    private let insertDirectory: OpaquePointer
    private var directoryIDs: [String: Int64] = [:]
    private(set) var indexTruncated = false
    init(store: ScanStore, root: URL) throws {
        self.store = store
        self.maximumEntries = store.maximumEntries
        self.root = ScanStore.canonical(root)
        self.excludedPath = ScanStore.canonical(store.directory).path
        db = try SQLConnection(url: store.databaseURL)
        insert = try db.statement("INSERT OR REPLACE INTO entries VALUES(?,?,?,?,?,?,?,?,?,?,?)")
        findDirectory = try db.statement("SELECT id FROM directories WHERE scan=? AND path=?")
        insertDirectory = try db.statement("INSERT INTO directories(scan,path) VALUES(?,?)")
        try db.execute("BEGIN IMMEDIATE")
        let scan = try db.statement("INSERT INTO catalog_scans(uuid) VALUES(?)")
        db.bind([id], to: scan)
        do { try db.run(scan) } catch { sqlite3_finalize(scan); throw error }
        sqlite3_finalize(scan)
        key = sqlite3_last_insert_rowid(db.handle)
        let pending = try db.statement("INSERT INTO pending_scans VALUES(?,?,?)")
        db.bind([id], to: pending); sqlite3_bind_int(pending, 2, getpid()); sqlite3_bind_double(pending, 3, started.timeIntervalSince1970)
        try db.run(pending); sqlite3_finalize(pending)
    }
    deinit {
        sqlite3_finalize(insert); sqlite3_finalize(findDirectory); sqlite3_finalize(insertDirectory)
        if !closed { discard() }
    }
    func excludes(_ path: String) -> Bool {
        // The startup data volume exposes the same home directory through a
        // firmlink alias. Never index our own growing database through either.
        func dataPath(_ value: String) -> String {
            let prefix = "/System/Volumes/Data"
            return value.hasPrefix(prefix + "/") ? String(value.dropFirst(prefix.count)) : value
        }
        let candidate = dataPath(path), excluded = dataPath(excludedPath)
        return candidate == excluded || candidate.hasPrefix(excluded + "/")
    }
    private func directoryID(for path: String) throws -> Int64 {
        if let cached = directoryIDs[path] { return cached }
        sqlite3_reset(findDirectory); sqlite3_clear_bindings(findDirectory)
        defer { sqlite3_reset(findDirectory) }
        sqlite3_bind_int64(findDirectory, 1, key); db.bind([path], to: findDirectory, startingAt: 2)
        let value: Int64
        if try db.step(findDirectory) { value = sqlite3_column_int64(findDirectory, 0) }
        else {
            sqlite3_reset(insertDirectory); sqlite3_clear_bindings(insertDirectory)
            sqlite3_bind_int64(insertDirectory, 1, key); db.bind([path], to: insertDirectory, startingAt: 2)
            try db.run(insertDirectory); value = sqlite3_last_insert_rowid(db.handle)
        }
        // Keep only a small working set; SQLite holds the complete directory map.
        if directoryIDs.count >= 4096 { directoryIDs.removeAll(keepingCapacity: true) }
        directoryIDs[path] = value
        return value
    }
    func record(_ entry: CatalogEntry) {
        guard failure == nil, !closed else { return }
        // Explicit limits exist only for fault-injection tests. Live indexes are
        // complete regardless of file count, folder depth or path-text length.
        let essential = entry.path == root.path || entry.parent == root.path
        if let maximumEntries, count >= maximumEntries, !essential { indexTruncated = true; return }
        do {
            let parent = try directoryID(for: entry.parent)
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            sqlite3_bind_int64(insert, 1, key); sqlite3_bind_int64(insert, 2, parent)
            db.bind([entry.name], to: insert, startingAt: 3)
            sqlite3_bind_int(insert, 4, entry.isDirectory ? 1 : 0)
            sqlite3_bind_int(insert, 5, entry.isPackage ? 1 : 0)
            sqlite3_bind_int64(insert, 6, entry.bytes); sqlite3_bind_int64(insert, 7, entry.logicalBytes)
            sqlite3_bind_double(insert, 8, entry.modified.timeIntervalSince1970)
            sqlite3_bind_int(insert, 9, Int32(entry.unreadable)); db.bind([entry.category.rawValue], to: insert, startingAt: 10)
            sqlite3_bind_int(insert, 11, entry.isSymbolicLink ? 1 : 0)
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
        try db.execute("DELETE FROM metadata WHERE key='rebuild_root'")
        let pending = try db.statement("DELETE FROM pending_scans WHERE id=?")
        db.bind([id], to: pending); try db.run(pending); sqlite3_finalize(pending)
        try db.execute("COMMIT"); closed = true
        // Keep the latest two completed scans per root; cancelled scans never
        // become selectable. Remove orphaned partial rows at the same time.
        let prune = try db.statement("DELETE FROM catalog_scans WHERE uuid IN (SELECT id FROM snapshots WHERE root=? ORDER BY finished DESC LIMIT -1 OFFSET 2)")
        db.bind([root.path], to: prune); try db.run(prune); sqlite3_finalize(prune)
        let pruneSnapshots = try db.statement("DELETE FROM snapshots WHERE root=? AND id NOT IN (SELECT id FROM snapshots WHERE root=? ORDER BY finished DESC LIMIT 2)")
        db.bind([root.path, root.path], to: pruneSnapshots); try db.run(pruneSnapshots); sqlite3_finalize(pruneSnapshots)
        try? store.maintain()
        return (try? store.snapshots(root: root.path).first) ?? snapshot
    }
    func discard() {
        guard !closed else { return }
        try? db.execute("ROLLBACK")
        if let s = try? db.statement("DELETE FROM catalog_scans WHERE uuid=?") { db.bind([id], to: s); try? db.run(s); sqlite3_finalize(s) }
        if let s = try? db.statement("DELETE FROM pending_scans WHERE id=?") { db.bind([id], to: s); try? db.run(s); sqlite3_finalize(s) }
        closed = true
    }
}
