import Foundation
import SwiftUI
import AppKit

/// One scan owns its callbacks; cancelling it makes all late results inert.
final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning(String), ready, failed(String) }
    @Published var phase: Phase = .idle
    @Published var overview = DiskOverview()
    @Published var apps: [AppEntry] = []
    @Published var junk: [JunkItem] = []
    @Published var rootTree: ScanItem?
    @Published var selection: SidebarTab = .overview
    @Published var homeBreakdown: [ScanItem] = []
    @Published var scanRoot: URL
    @Published var browserURL: URL
    @Published var browserItems: [ScanItem] = []
    @Published var browserSelection: Set<String> = []
    @Published var browserIsScanning = false
    @Published var browserUnreadable = 0
    @Published var stageMessages: [String: String] = [:]
    @Published var completedStages: Set<String> = []
    @Published var scanStarted: Date?
    @Published var showingCleanup = false
    @Published var showingCommandPalette = false
    @Published var cleanupCandidates: [CleanupCandidate] = []
    @Published var cleanupSelection: Set<String> = []
    @Published var isCleaning = false
    @Published var cleaningLabel = "Moving to Trash…"
    @Published var notice: String?
    @Published var errorMessage: String?

    @Published var snapshot: ScanSnapshot?
    @Published var previousSnapshot: ScanSnapshot?
    @Published var savedSnapshots: [ScanSnapshot] = []
    @Published var categoryTotals: [CategoryTotal] = []
    @Published var largestFiles: [CatalogEntry] = []
    @Published var changes: [ScanChange] = []
    @Published var searchResults: [CatalogEntry] = []
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var mapURL: URL
    @Published var mapEntries: [CatalogEntry] = []
    @Published var mapSelected: CatalogEntry?
    @Published var mapLoading = false
    @Published var cleanupHistory: [CleanupEvent] = []
    @Published var restoringItems: Set<String> = []
    @Published var scannedItemCount = 0
    @Published var showingSavedScan = false
    @Published var showingClearScanConfirmation = false
    @Published var localIndexBytes: Int64 = 0
    @Published var persistenceWarning: String?
    @Published var isBootstrapping = false
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var duplicateHasRun = false
    @Published var duplicateIsScanning = false
    @Published var duplicateProgress = ""
    @Published var duplicateSkipped = 0
    @Published var duplicateError: String?
    var duplicateToken = ScanCancellation()
    var duplicateID = UUID()
    var cleanupDuplicateGroups: [DuplicateGroup]?
    var cleanupDuplicateEntries: [String: CatalogEntry] = [:]
    @Published var navigationHistory: [URL] = []
    @Published var navigationIndex = -1
    @Published var mapMeasuredAt: Date?
    var mapDates: [String: Date] = [:]
    @Published var mapError: String?
    @Published var inventoryDate: Date?
    var restoringNavigation = false
    var mapCache: [String: [CatalogEntry]] = [:]
    var mapCacheOrder: [String] = []
    var mapCancellation = ScanCancellation()
    let store: ScanStore?
    var searchWork: DispatchWorkItem?
    var searchID = UUID()
    var insightID = UUID()
    var mapID = UUID()
    var snapshotLoadID = UUID()
    private let inventory: AppInventoryScanning
    private let junkDetector: JunkScanning
    private var cancellation = ScanCancellation()
    private var browserCancellation = ScanCancellation()
    private var scanID = UUID()
    private var browserID = UUID()
    private var pendingStages: Set<String> = []
    private var directoryCache: [String: (items: [ScanItem], unreadable: Int)] = [:]

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         inventory: AppInventoryScanning = AppInventory(),
         junkDetector: JunkScanning = JunkDetector(), store: ScanStore? = nil) {
        self.store = store
        self.scanRoot = ScanStore.canonical(URL(fileURLWithPath: home))
        self.browserURL = ScanStore.canonical(URL(fileURLWithPath: home))
        self.mapURL = ScanStore.canonical(URL(fileURLWithPath: home))
        self.inventory = inventory
        self.junkDetector = junkDetector
    }

    var isScanning: Bool { if case .scanning = phase { return true }; return false }
    var totalRelatedBytes: Int64 {
        var seen = Set<String>()
        return apps.flatMap(\.relatedFiles).filter { seen.insert($0.path).inserted }.reduce(0) { $0 + $1.bytes }
    }
    var totalJunkBytes: Int64 { junk.reduce(0) { $0 + $1.bytes } }
    var totalAppBytes: Int64 { apps.reduce(0) { $0 + $1.allocatedBytes } }
    var selectedCleanupBytes: Int64 { cleanupCandidates.filter { cleanupSelection.contains($0.id) }.reduce(0) { $0 + $1.bytes } }
    var browserTotal: Int64 { browserItems.reduce(0) { $0 + $1.allocatedBytes } }
    var rootName: String {
        if scanRoot.path == FileManager.default.homeDirectoryForCurrentUser.path { return "Home folder" }
        if scanRoot.path == "/System/Volumes/Data" { return "Startup disk" }
        if scanRoot.path == "/" { return "File system" }
        return scanRoot.lastPathComponent.isEmpty ? "File system" : scanRoot.lastPathComponent
    }

    func runFullScan(includeInventories: Bool = true) {
        guard !isScanning, !isCleaning else { return }
        isBootstrapping = false
        snapshotLoadID = UUID(); insightID = UUID()
        stopDuplicateSearch()
        duplicateGroups = []; duplicateHasRun = false
        if notice?.hasPrefix("Scan stopped.") == true { notice = nil }
        scanID = UUID()
        let id = scanID
        cancellation = ScanCancellation()
        let token = cancellation
        let lastItems: [ScannedEntry] = snapshot?.root == scanRoot.path ? homeBreakdown.map {
            ScannedEntry(url: $0.url, name: $0.name, isDirectory: $0.isDirectory,
                isPackage: $0.isPackage, bytes: $0.allocatedBytes, unreadable: $0.isUnreadable ? 1 : 0)
        } : []
        let lastSnapshot = snapshot?.root == scanRoot.path ? snapshot : nil
        pendingStages = includeInventories ? ["Folders", "Apps", "Cleanup"] : ["Folders"]
        completedStages = []
        stageMessages = ["Folders": "Reading folders…", "Apps": "Finding installed apps…", "Cleanup": "Finding caches…"]
        scanStarted = Date()
        scannedItemCount = 0
        showingSavedScan = false
        phase = .scanning("Scanning \(rootName)…")
        overview = DiskScanner.overview(for: scanRoot.path)
        homeBreakdown = []; directoryCache = [:]
        browserCancellation.cancel()
        browserIsScanning = false
        browserID = UUID()
        browserURL = scanRoot
        browserItems = []
        browserSelection = []
        let rootURL = scanRoot
        rootTree = ScanItem(url: rootURL, name: rootName, isDirectory: true, isPackage: false, depth: 0)
        rootTree?.children = []

        let persistence = store
        DispatchQueue.global(qos: .userInitiated).async {
            var writer: ScanWriter?
            do { writer = try persistence?.begin(root: rootURL) }
            catch { DispatchQueue.main.async { self.persistenceWarning = error.localizedDescription } }
            let result = DiskScanner().scanDirectory(at: rootURL, onProgress: { path in
                let count = writer?.count ?? 0
                DispatchQueue.main.async {
                    self.progress(path, stage: "Folders", id: id)
                    if self.scanID == id { self.scannedItemCount = count }
                }
            }, isCancelled: { token.isCancelled }, onEntry: { entry in
                DispatchQueue.main.async {
                    guard self.scanID == id, !token.isCancelled else { return }
                    self.homeBreakdown.append(self.makeItem(entry))
                    self.homeBreakdown.sort { $0.allocatedBytes > $1.allocatedBytes }
                    self.overview.scannedBytes = self.homeBreakdown.reduce(0) { $0 + $1.allocatedBytes }
                    if self.browserURL == rootURL { self.browserItems = self.homeBreakdown }
                }
            }, catalog: writer)
            if token.isCancelled { writer?.discard(); return }
            // A revoked permission or disconnected volume must not erase the
            // last useful index with an apparently successful empty scan.
            if result.children.isEmpty && result.unreadable > 0 {
                writer?.discard()
                DispatchQueue.main.async {
                    guard self.scanID == id, !token.isCancelled else { return }
                    let restoredItems = lastItems.map { self.makeItem($0) }
                    self.homeBreakdown = restoredItems
                    self.rootTree?.children = restoredItems
                    self.overview.scannedBytes = lastSnapshot?.bytes ?? 0
                    self.overview.unreadableCount += result.unreadable
                    if self.browserURL == rootURL { self.browserItems = restoredItems; self.browserUnreadable = result.unreadable }
                    self.snapshot = lastSnapshot; self.showingSavedScan = lastSnapshot != nil
                    self.scannedItemCount = lastSnapshot?.entryCount ?? 0
                    self.notice = "This folder could not be read. Check its availability and access permissions."
                        + (lastSnapshot == nil ? "" : " Your last completed scan was kept.")
                    self.finish("Folders", id: id)
                }
                return
            }
            var saved: ScanSnapshot?
            do { saved = try writer?.complete(bytes: result.bytes, unreadable: result.unreadable) }
            catch {
                writer?.discard()
                DispatchQueue.main.async { self.persistenceWarning = error.localizedDescription }
            }
            let completedSnapshot = saved
            DispatchQueue.main.async {
                guard self.scanID == id, !token.isCancelled else { return }
                let items = result.children.map { self.makeItem($0) }
                self.homeBreakdown = items
                self.rootTree?.children = items
                self.rootTree?.allocatedBytes = result.bytes
                self.overview.scannedBytes = result.bytes
                self.overview.unreadableCount += result.unreadable
                self.directoryCache[rootURL.path] = (items, result.unreadable)
                if self.browserURL == rootURL { self.browserItems = items; self.browserUnreadable = result.unreadable }
                self.resetMapCache()
                self.snapshot = completedSnapshot
                self.scannedItemCount = completedSnapshot?.entryCount ?? 0
                self.directoryCache = [rootURL.path: (items, result.unreadable)]
                if let completedSnapshot {
                    let rootEntries = result.children.map { entry in
                        CatalogEntry(path: entry.url.path, parent: rootURL.path, name: entry.name, isDirectory: entry.isDirectory,
                            isPackage: entry.isPackage, bytes: entry.bytes, logicalBytes: 0, modified: .distantPast,
                            unreadable: entry.unreadable, category: StorageCategory.classify(path: entry.url.path, isDirectory: entry.isDirectory), isSymbolicLink: false)
                    }
                    self.cacheMap(rootEntries, at: rootURL, measuredAt: completedSnapshot.finished)
                    let location = self.browserURL
                    let selectedTab = self.selection
                    self.stopBrowserWork()
                    self.loadInsights(for: completedSnapshot)
                    if location != rootURL, self.containsInSnapshot(location.path, root: completedSnapshot.root) {
                        self.browse(location)
                        self.selection = selectedTab
                    }
                }
                self.finish("Folders", id: id)
            }
        }
        if includeInventories { startInventories(id: id) }
    }

    func refreshInventories() {
        guard !isScanning, !isCleaning else { return }
        scanID = UUID(); pendingStages = ["Apps", "Cleanup"]; completedStages = []
        stageMessages = ["Apps": "Finding installed apps…", "Cleanup": "Measuring caches…"]
        phase = .scanning("Updating apps and cleanup…")
        startInventories(id: scanID)
    }

    private func startInventories(id: UUID) {
        inventory.buildInventory(onProgress: { message in
            DispatchQueue.main.async { self.progress(message, stage: "Apps", id: id) }
        }) { entries in
            guard self.scanID == id, self.pendingStages.contains("Apps") else { return }
            self.apps = entries
            self.finish("Apps", id: id)
        }
        junkDetector.detect(onProgress: { message in
            DispatchQueue.main.async { self.progress(message, stage: "Cleanup", id: id) }
        }) { items, unreadable in
            guard self.scanID == id, self.pendingStages.contains("Cleanup") else { return }
            self.junk = items
            self.overview.unreadableCount += unreadable
            self.finish("Cleanup", id: id)
        }
    }

    func makeItem(_ entry: ScannedEntry) -> ScanItem {
        let item = ScanItem(url: entry.url, name: entry.name, isDirectory: entry.isDirectory, isPackage: entry.isPackage, depth: 0)
        item.allocatedBytes = entry.bytes
        item.isUnreadable = entry.unreadable > 0
        return item
    }

    private func progress(_ message: String, stage: String, id: UUID) {
        guard scanID == id, pendingStages.contains(stage) else { return }
        stageMessages[stage] = message
        phase = .scanning(message)
    }

    private func finish(_ stage: String, id: UUID) {
        guard scanID == id else { return }
        pendingStages.remove(stage)
        completedStages.insert(stage)
        stageMessages[stage] = "Complete"
        if pendingStages.isEmpty {
            phase = .ready; refreshDiskAccess()
            if completedStages.contains("Apps") && completedStages.contains("Cleanup") { inventoryDate = Date() }
            if completedStages.contains("Apps") && completedStages.contains("Cleanup"), let store {
                let entries = apps; let candidates = junk
                DispatchQueue.global(qos: .utility).async {
                    do { try store.saveInventory(apps: entries, junk: candidates) }
                    catch { DispatchQueue.main.async { self.persistenceWarning = error.localizedDescription } }
                }
            }
        }
    }

    func cancelScan() {
        isBootstrapping = false
        snapshotLoadID = UUID(); insightID = UUID()
        cancellation.cancel(); inventory.cancel(); junkDetector.cancel()
        scanID = UUID(); pendingStages = []; stageMessages = [:]
        phase = .ready
        notice = "Scan stopped. The visible sizes are partial; scan again for complete results."
    }

    func refreshDiskAccess() { overview.needsFullDiskAccess = FullDiskAccess.status() == .denied }

    func refreshVolumeCapacity() {
        let root = scanRoot
        DispatchQueue.global(qos: .utility).async {
            let current = DiskScanner.overview(for: root.path)
            DispatchQueue.main.async {
                guard self.scanRoot == root else { return }
                self.overview.volumeName = current.volumeName
                self.overview.totalCapacity = current.totalCapacity
                self.overview.freeSpace = current.freeSpace
            }
        }
    }

    func stopBrowserWork() {
        browserCancellation.cancel(); browserID = UUID(); browserIsScanning = false
        searchID = UUID(); searchWork?.cancel(); isSearching = false
        mapID = UUID(); mapLoading = false; mapCancellation.cancel()
    }

    private func cacheDirectory(_ path: String, items: [ScanItem], unreadable: Int) {
        if directoryCache.count >= 24 || directoryCache.values.reduce(0, { $0 + $1.items.count }) + items.count > 50_000 { directoryCache = [:] }
        if items.count <= 50_000 { directoryCache[path] = (items, unreadable) }
    }

    func clearDirectoryCache() { directoryCache = [:] }

    func containsInSnapshot(_ path: String, root: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    func selectRoot(_ url: URL, presentation: SidebarTab? = nil) {
        guard !isCleaning else { return }
        snapshotLoadID = UUID(); insightID = UUID()
        stopDuplicateSearch(); duplicateGroups = []; duplicateHasRun = false
        stopBrowserWork()
        if isScanning { cancelScan() }
        let target = presentation ?? (selection == .spaceMap || selection == .browser ? selection : .overview)
        scanRoot = ScanStore.canonical(url); selection = target
        resetMapCache(); rememberLocation(scanRoot)
        mapURL = scanRoot; mapEntries = []; snapshot = nil; previousSnapshot = nil; mapSelected = nil
        largestFiles = []; categoryTotals = []; changes = []; searchResults = []
        notice = nil
        restoreOrScanRoot()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder or volume to analyze"
        panel.prompt = "Analyze"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.selectRoot(url) }
        }
        if let window = NSApplication.shared.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func browse(_ url: URL, refresh: Bool = false) {
        guard !isCleaning else { return }
        let url = ScanStore.canonical(url)
        selection = .browser
        rememberLocation(url)
        browserCancellation.cancel()
        browserCancellation = ScanCancellation()
        let token = browserCancellation
        browserID = UUID(); let id = browserID
        browserURL = url; browserSelection = []; browserUnreadable = 0
        if mapURL != url { mapURL = url; mapEntries = []; mapSelected = nil }
        if !refresh, let cached = directoryCache[url.path] {
            browserItems = cached.items; browserUnreadable = cached.unreadable; browserIsScanning = false; return
        }
        if !refresh, let snapshot, snapshot.indexTruncated != true, let store,
           containsInSnapshot(url.path, root: snapshot.root) {
            browserItems = []; browserIsScanning = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let entries = try store.children(snapshot: snapshot.id, parent: url.path)
                    DispatchQueue.main.async {
                        guard self.browserID == id else { return }
                        self.browserItems = entries.map { $0.scanItem() }
                        self.browserUnreadable = entries.reduce(0) { $0 + $1.unreadable }
                        self.cacheDirectory(url.path, items: self.browserItems, unreadable: self.browserUnreadable)
                        self.browserIsScanning = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.browserID == id else { return }
                        self.browserIsScanning = false; self.errorMessage = error.localizedDescription
                    }
                }
            }
            return
        }
        if url == scanRoot, isScanning, !completedStages.contains("Folders") {
            browserItems = homeBreakdown; browserIsScanning = false; return
        }
        browserItems = []; browserIsScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = DiskScanner().scanDirectory(at: url, isCancelled: { token.isCancelled }, onEntry: { entry in
                DispatchQueue.main.async {
                    guard self.browserID == id, !token.isCancelled else { return }
                    self.browserItems.append(self.makeItem(entry))
                    self.browserItems.sort { $0.allocatedBytes > $1.allocatedBytes }
                }
            })
            DispatchQueue.main.async {
                guard self.browserID == id, !token.isCancelled else { return }
                self.browserItems = result.children.map { self.makeItem($0) }
                self.browserUnreadable = result.unreadable
                self.cacheDirectory(url.path, items: self.browserItems, unreadable: result.unreadable)
                self.browserIsScanning = false
            }
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    func openTrash() { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }

    func reviewCleanup(_ candidates: [CleanupCandidate], initiallySelected: Set<String>? = nil) {
        guard !isCleaning else { return }
        cleanupDuplicateGroups = nil; cleanupDuplicateEntries = [:]
        do {
            cleanupCandidates = try CleanupService(allowedRoots: [scanRoot]).validate(candidates)
            guard !cleanupCandidates.isEmpty else { return }
            cleanupSelection = initiallySelected ?? Set(cleanupCandidates.map(\.id))
            showingCleanup = true
        } catch { errorMessage = error.localizedDescription }
    }

    func reviewApp(_ app: AppEntry) {
        let candidates = [CleanupCandidate(url: app.appURL, bytes: app.allocatedBytes, reason: "Application")] + app.relatedFiles.map {
            CleanupCandidate(url: URL(fileURLWithPath: $0.path), bytes: $0.bytes, reason: "Possible related \($0.category.rawValue.lowercased()) — review before removing")
        }
        // Support files can contain personal data. Uninstall selects only the app by default.
        reviewCleanup(candidates, initiallySelected: [])
        if showingCleanup { cleanupSelection = Set(cleanupCandidates.filter { $0.reason == "Application" }.map(\.id)) }
    }

    func confirmCleanup() {
        let selected = cleanupCandidates.filter { cleanupSelection.contains($0.id) }
        guard !selected.isEmpty else { return }
        if isScanning { cancelScan() }
        browserCancellation.cancel(); browserIsScanning = false
        showingCleanup = false; isCleaning = true; cleaningLabel = "Moving to Trash…"
        let root = scanRoot
        let persistence = store
        let duplicateContext = cleanupDuplicateGroups
        let duplicateEntries = selected.compactMap { cleanupDuplicateEntries[$0.id] }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: CleanupResult
            do {
                var candidates = selected
                if let duplicateContext {
                    guard duplicateEntries.count == selected.count else { throw StoreError(message: "Duplicate review changed. Check those copies again.") }
                    candidates = try DuplicateFinder.validateForCleanup(entries: duplicateEntries, groups: duplicateContext)
                }
                result = CleanupService(allowedRoots: [root]).moveToTrash(candidates)
            } catch { result = CleanupResult(moved: [], failures: [error.localizedDescription]) }
            let event = CleanupEvent(id: UUID().uuidString, date: Date(), receipts: result.receipts, failures: result.failures, restored: [])
            var historyError: String?
            do { try persistence?.saveHistory(event) } catch { historyError = error.localizedDescription }
            let updatedHistory = (try? persistence?.history()) ?? []
            let saveError = historyError
            DispatchQueue.main.async {
                self.isCleaning = false
                self.cleanupHistory = updatedHistory
                if let saveError { self.persistenceWarning = "Cleanup history could not be saved: " + saveError }
                if !result.moved.isEmpty {
                    self.notice = "Moved \(result.moved.count) item(s) to Trash. Empty Trash in Finder when you are ready to reclaim the space."
                    self.runFullScan()
                }
                if !result.failures.isEmpty { self.errorMessage = result.failures.joined(separator: "\n") }
            }
        }
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case overview = "Overview", spaceMap = "Space Map", search = "Find Files", changes = "What Changed"
    case duplicates = "Duplicates", plan = "Make Room"
    case apps = "Applications", junk = "Cleanup", history = "Activity", browser = "File Browser"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .spaceMap: return "rectangle.3.group.fill"
        case .search: return "magnifyingglass"
        case .changes: return "arrow.up.arrow.down"
        case .history: return "clock.arrow.circlepath"
        case .duplicates: return "square.on.square"
        case .plan: return "sparkles.rectangle.stack"
        case .apps: return "app.badge"
        case .junk: return "sparkles"
        case .browser: return "folder"
        }
    }
}
