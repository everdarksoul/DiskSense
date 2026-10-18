import Foundation

/// A compact persisted record, shared by the map, browser, search and comparisons.
struct CatalogEntry: Identifiable, Codable, Hashable {
    var id: String { path }
    let path: String
    let parent: String
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let bytes: Int64
    let logicalBytes: Int64
    let modified: Date
    let unreadable: Int
    let category: StorageCategory
    let isSymbolicLink: Bool
    var url: URL { URL(fileURLWithPath: path) }

    func scanItem() -> ScanItem {
        let item = ScanItem(url: url, name: name, isDirectory: isDirectory, isPackage: isPackage, depth: 0)
        item.allocatedBytes = bytes; item.isUnreadable = unreadable > 0
        return item
    }
}

enum StorageCategory: String, Codable, CaseIterable, Identifiable {
    case applications = "Applications", media = "Media", documents = "Documents"
    case development = "Development", caches = "Caches", other = "Other"
    var id: String { rawValue }
    var colorHex: String {
        switch self {
        case .applications: return "7978F5"
        case .media: return "DF82A9"
        case .documents: return "55B6CB"
        case .development: return "E3AC64"
        case .caches: return "DA7966"
        case .other: return "7EA398"
        }
    }
    var symbol: String {
        switch self {
        case .applications: return "app.fill"
        case .media: return "photo.on.rectangle"
        case .documents: return "doc.text"
        case .development: return "hammer"
        case .caches: return "shippingbox"
        case .other: return "folder"
        }
    }
    static func classify(path: String, isDirectory: Bool) -> StorageCategory {
        let lower = path.lowercased()
        let name = (lower as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        if lower.contains("/caches/") || lower.contains("/.cache/") || ["caches", ".cache", "_cacache"].contains(name) { return .caches }
        if ext == "app" || lower.contains(".app/") || lower.contains("/applications/") { return .applications }
        if ["jpg","jpeg","png","heic","gif","tiff","raw","mp4","mov","mkv","mp3","wav","flac","m4a","photoslibrary"].contains(ext)
            || ["pictures","movies","music"].contains(name) { return .media }
        if lower.contains("/node_modules/") || lower.contains("/.git/") || lower.contains("/deriveddata/")
            || ["node_modules",".git","deriveddata",".build","projects","developer"].contains(name)
            || ["swift","rs","go","py","js","ts","tsx","c","cpp","h","xcodeproj"].contains(ext) { return .development }
        if ["pdf","doc","docx","xls","xlsx","csv","txt","md","ppt","pptx","pages","numbers","key"].contains(ext) || name == "documents" { return .documents }
        return .other
    }
}

struct ScanSnapshot: Identifiable, Codable, Equatable {
    let id: String
    let root: String
    let started: Date
    let finished: Date
    let bytes: Int64
    let entryCount: Int
    let unreadable: Int
    var indexTruncated: Bool? = nil
    var duration: TimeInterval { finished.timeIntervalSince(started) }
}

struct ScanChange: Identifiable, Codable {
    var id: String { path }
    let path: String
    let before: Int64
    let after: Int64
    var delta: Int64 { after - before }
}

struct CategoryTotal: Identifiable, Codable {
    var id: String { category.rawValue }
    let category: StorageCategory
    let bytes: Int64
}

struct SavedInventory: Codable {
    let date: Date
    let apps: [AppEntry]
    let junk: [JunkItem]
}

struct TrashReceipt: Codable, Identifiable, Hashable {
    var id: String { originalURL.path }
    let originalURL: URL
    let trashURL: URL?
    let bytes: Int64
    let trashIdentity: CleanupIdentity?

    init(originalURL: URL, trashURL: URL?, bytes: Int64, trashIdentity: CleanupIdentity? = nil) {
        self.originalURL = originalURL; self.trashURL = trashURL
        self.bytes = bytes; self.trashIdentity = trashIdentity
    }
}

struct CleanupEvent: Codable, Identifiable {
    let id: String
    let date: Date
    let receipts: [TrashReceipt]
    let failures: [String]
    var restored: [String]
    var movedBytes: Int64 { receipts.reduce(0) { $0 + $1.bytes } }
}
