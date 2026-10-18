import Foundation

/// A node in the disk-usage tree (OmniDiskSweeper-style).
/// Reference type so we can mutate sizes in place during a background sweep.
final class ScanItem: Identifiable, ObservableObject {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool          // .app / bundle — treat as leaf
    let depth: Int

    @Published var allocatedBytes: Int64 = 0
    @Published var childCount: Int = 0
    @Published var isSizing: Bool = false
    @Published var isUnreadable: Bool = false
    @Published var children: [ScanItem]? = nil   // nil = not yet expanded (lazy)

    init(url: URL, name: String, isDirectory: Bool, isPackage: Bool, depth: Int) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.depth = depth
    }
}

/// One app found in the inventory, plus its scattered related files.
struct AppEntry: Identifiable, Codable {
    var id: String { appURL.path }
    let name: String
    let bundleIdentifier: String?
    let appURL: URL
    let allocatedBytes: Int64
    let version: String?
    var relatedFiles: [RelatedFile] = []
    var relatedBytes: Int64 { relatedFiles.reduce(0) { $0 + $1.bytes } }
    /// Bundle id used for matching (falls back to name when missing).
    var matchKey: String { bundleIdentifier ?? name }
}

/// A leftover/associated file discovered by matching against the folder whitelist.
struct RelatedFile: Identifiable, Hashable, Codable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let category: Category

    enum Category: String, CaseIterable, Codable {
        case preferences = "Preferences"
        case caches = "Caches"
        case applicationSupport = "Application Support"
        case containers = "Containers"
        case groupContainers = "Group Containers"
        case savedState = "Saved State"
        case launchAgents = "Launch Agents"
        case launchDaemons = "Launch Daemons"
        case receipts = "pkg Receipts"
        case logs = "Logs"
        case other = "Other"

        var symbol: String {
            switch self {
            case .preferences: return "slider.horizontal.3"
            case .caches: return "internaldrive"
            case .applicationSupport: return "folder"
            case .containers: return "shippingbox"
            case .groupContainers: return "person.3"
            case .savedState: return "arrow.uturn.backward.square"
            case .launchAgents: return "antenna.radiowaves.left.and.right"
            case .launchDaemons: return "server.rack"
            case .receipts: return "checkmark.seal"
            case .logs: return "doc.text"
            case .other: return "doc"
            }
        }
    }
}

/// A junk candidate surfaced by the heuristics layer.
struct JunkItem: Identifiable, Codable {
    var id: String { path }
    let name: String
    let path: String
    let bytes: Int64
    let kind: Kind
    let note: String

    enum Kind: String, Codable {
        case systemCache = "User caches"
        case devCache = "Developer caches"
        case logs = "Logs"
        case savedState = "Saved application state"
        case orphaned = "Orphaned leftovers"
        case trash = "Trash"
        case staleContainer = "Stale containers"
        case buildArtifacts = "Build artifacts"
        case pkgReceipts = "Package receipts"

        var symbol: String {
            switch self {
            case .systemCache: return "internaldrive"
            case .devCache: return "hammer"
            case .logs: return "doc.text"
            case .savedState: return "arrow.uturn.backward.square"
            case .orphaned: return "questionmark.folder"
            case .trash: return "trash"
            case .staleContainer: return "shippingbox"
            case .buildArtifacts: return "wrench.and.screwdriver"
            case .pkgReceipts: return "checkmark.seal"
            }
        }
    }
}

/// Aggregated capacity numbers for the Overview.
struct DiskOverview: Codable {
    var volumeName = "Storage volume"
    var totalCapacity: Int64 = 0
    var freeSpace: Int64 = 0
    var scannedBytes: Int64 = 0
    var unreadableCount: Int = 0
    var needsFullDiskAccess: Bool = false

    var usedBytes: Int64 { totalCapacity - freeSpace }
}
