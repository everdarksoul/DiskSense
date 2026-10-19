import AppKit
import Foundation
import UniformTypeIdentifiers

extension AppModel {
    static func live() -> AppModel {
        do { return AppModel(store: try ScanStore.live()) }
        catch {
            let model = AppModel()
            model.persistenceWarning = "Saved scans are unavailable: \(error.localizedDescription)"
            return model
        }
    }

    /// Reopen the last completed index without touching every scanned file.
    func bootstrap() {
        guard phase == .idle, !isBootstrapping else { return }
        guard let store else { runFullScan(); return }
        isBootstrapping = true
        refreshVolumeCapacity()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try store.maintain()
                let saved = try store.snapshots()
                let inventory = try? store.inventory()
                let history = try store.history()
                let latest = saved.first
                let rebuildRoot = latest == nil ? try store.preferredRebuildRoot() : nil
                let children = try latest.map { try store.children(snapshot: $0.id, parent: $0.root) } ?? []
                DispatchQueue.main.async {
                    self.isBootstrapping = false
                    guard self.phase == .idle else { return }
                    self.savedSnapshots = saved; self.cleanupHistory = history
                    self.localIndexBytes = store.localDataBytes()
                    if let inventory { self.apps = inventory.apps; self.junk = inventory.junk; self.inventoryDate = inventory.date }
                    if let latest {
                        self.presentSaved(latest, children: children)
                        self.loadInsights(for: latest)
                    } else {
                        if let rebuildRoot {
                            self.scanRoot = ScanStore.canonical(rebuildRoot)
                            self.browserURL = self.scanRoot; self.mapURL = self.scanRoot
                            self.notice = "Rebuilding your saved scan with the complete file index. Cleanup history was kept."
                        }
                        self.runFullScan(includeInventories: self.inventoryDate == nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBootstrapping = false
                    self.persistenceWarning = error.localizedDescription
                    if self.phase == .idle { self.runFullScan() }
                }
            }
        }
    }

    private func presentSaved(_ saved: ScanSnapshot, children: [CatalogEntry]) {
        stopBrowserWork()
        clearDirectoryCache(); resetMapCache()
        scanRoot = URL(fileURLWithPath: saved.root); browserURL = scanRoot; mapURL = scanRoot
        snapshot = saved; showingSavedScan = true
        homeBreakdown = children.map { $0.scanItem() }; browserItems = homeBreakdown
        mapEntries = children; mapSelected = nil; cacheMap(children, at: scanRoot); rememberLocation(scanRoot)
        overview = DiskScanner.overview(for: saved.root)
        overview.scannedBytes = saved.bytes; overview.unreadableCount = saved.unreadable
        browserUnreadable = saved.unreadable
        scannedItemCount = saved.entryCount
        scanStarted = saved.started
        completedStages = ["Folders"]
        if !apps.isEmpty { completedStages.insert("Apps") }
        if !junk.isEmpty { completedStages.insert("Cleanup") }
        rootTree = ScanItem(url: scanRoot, name: rootName, isDirectory: true, isPackage: false, depth: 0)
        rootTree?.children = homeBreakdown; rootTree?.allocatedBytes = saved.bytes
        phase = .ready
    }

    func restoreOrScanRoot() {
        guard let store else { runFullScan(includeInventories: inventoryDate == nil); return }
        let root = scanRoot; let request = snapshotLoadID; let tab = selection
        phase = .ready; isBootstrapping = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let saved = try store.snapshots(root: root.path).first
                let children = try saved.map { try store.children(snapshot: $0.id, parent: root.path) } ?? []
                DispatchQueue.main.async {
                    guard self.snapshotLoadID == request, self.scanRoot == root else { return }
                    self.isBootstrapping = false
                    if let saved {
                        self.presentSaved(saved, children: children)
                        self.selection = tab; self.loadInsights(for: saved)
                    } else { self.runFullScan(includeInventories: self.inventoryDate == nil) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.snapshotLoadID == request else { return }
                    self.isBootstrapping = false; self.persistenceWarning = error.localizedDescription
                    self.runFullScan(includeInventories: self.inventoryDate == nil)
                }
            }
        }
    }

    func openSnapshot(_ saved: ScanSnapshot) {
        guard !isCleaning else { return }
        if isScanning { cancelScan() }
        guard let store else { return }
        snapshotLoadID = UUID(); let request = snapshotLoadID
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try store.children(snapshot: saved.id, parent: saved.root)
                DispatchQueue.main.async {
                    guard self.snapshotLoadID == request else { return }
                    self.stopDuplicateSearch(); self.duplicateGroups = []; self.duplicateHasRun = false
                    self.presentSaved(saved, children: entries)
                    self.selection = .overview; self.notice = nil
                    self.loadInsights(for: saved)
                }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }

    func loadInsights(for saved: ScanSnapshot) {
        guard let store else { return }
        insightID = UUID(); let request = insightID
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let snapshots = try store.snapshots()
                let previous = snapshots.first { $0.root == saved.root && $0.finished < saved.finished }
                let changes = try previous.map { try store.changes(current: saved, previous: $0) } ?? []
                let categories = saved.indexTruncated == true ? [] : try store.categories(snapshot: saved.id)
                let largest = try store.search(snapshot: saved.id)
                DispatchQueue.main.async {
                    guard self.insightID == request, self.snapshot?.id == saved.id else { return }
                    self.savedSnapshots = snapshots; self.previousSnapshot = previous
                    self.localIndexBytes = store.localDataBytes()
                    self.changes = changes; self.categoryTotals = categories
                    self.largestFiles = Array(largest.prefix(12))
                    self.loadMap(self.containsInSnapshot(self.mapURL.path, root: saved.root) ? self.mapURL : URL(fileURLWithPath: saved.root))
                }
            } catch { DispatchQueue.main.async { self.persistenceWarning = error.localizedDescription } }
        }
    }

    var displayMapEntries: [CatalogEntry] {
        if !mapEntries.isEmpty { return mapEntries }
        guard mapURL.path == scanRoot.path else { return [] }
        return homeBreakdown.map { item in
            CatalogEntry(path: item.url.path, parent: scanRoot.path, name: item.name,
                isDirectory: item.isDirectory, isPackage: item.isPackage, bytes: item.allocatedBytes,
                logicalBytes: 0, modified: Date(timeIntervalSince1970: 0), unreadable: item.isUnreadable ? 1 : 0,
                category: StorageCategory.classify(path: item.url.path, isDirectory: item.isDirectory), isSymbolicLink: false)
        }
    }

    func loadMap(_ url: URL, refresh: Bool = false) {
        guard !isCleaning else { return }
        let url = ScanStore.canonical(url)
        let changed = mapURL != url
        rememberLocation(url)
        if changed { mapSelected = nil }
        mapCancellation.cancel(); mapCancellation = ScanCancellation()
        let token = mapCancellation
        mapID = UUID(); let request = mapID
        mapError = nil
        if !refresh, let cached = mapCache[url.path] {
            mapURL = url; browserURL = url; mapEntries = cached; mapLoading = false; mapMeasuredAt = mapDates[url.path]
            return
        }
        if let snapshot, !containsInSnapshot(url.path, root: snapshot.root) {
            selectRoot(url, presentation: .spaceMap)
            return
        }
        mapURL = url; browserURL = url; mapEntries = []; mapLoading = true; mapMeasuredAt = nil
        if isScanning && url == scanRoot && !completedStages.contains("Folders") {
            mapLoading = false; return
        }
        let saved = snapshot; let persistence = store
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries: [CatalogEntry]
                if !refresh, let saved, saved.indexTruncated != true, let persistence {
                    entries = try persistence.children(snapshot: saved.id, parent: url.path)
                } else {
                    let result = DiskScanner().scanDirectory(at: url, isCancelled: { token.isCancelled })
                    if token.isCancelled { return }
                    if result.children.isEmpty && result.unreadable > 0 { throw StoreError(message: "This folder could not be read. Check that the drive is connected and access is allowed.") }
                    entries = result.children.map { entry in
                        CatalogEntry(path: entry.url.path, parent: url.path, name: entry.name, isDirectory: entry.isDirectory,
                            isPackage: entry.isPackage, bytes: entry.bytes, logicalBytes: 0, modified: .distantPast,
                            unreadable: entry.unreadable, category: StorageCategory.classify(path: entry.url.path, isDirectory: entry.isDirectory), isSymbolicLink: false)
                    }
                }
                DispatchQueue.main.async {
                    guard self.mapID == request, !token.isCancelled else { return }
                    self.cacheMap(entries, at: url, measuredAt: !refresh && saved?.indexTruncated != true ? saved?.finished : Date())
                    self.mapMeasuredAt = self.mapDates[url.path]
                    self.mapEntries = entries; self.mapLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.mapID == request else { return }
                    self.mapLoading = false; self.mapError = error.localizedDescription
                }
            }
        }
    }

    func findFiles(text: String, minimumBytes: Int64 = 0, category: StorageCategory? = nil, filesOnly: Bool = true, olderThan: Date? = nil) {
        searchWork?.cancel(); searchID = UUID(); let request = searchID
        guard let snapshot, let store else { searchResults = []; isSearching = false; return }
        isSearching = true; searchError = nil
        let work = DispatchWorkItem {
            do {
                let matches = try store.search(snapshot: snapshot.id, text: text, minimumBytes: minimumBytes, category: category, filesOnly: filesOnly, olderThan: olderThan)
                DispatchQueue.main.async {
                    guard self.searchID == request else { return }
                    self.searchResults = matches; self.isSearching = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.searchID == request else { return }
                    self.searchError = error.localizedDescription; self.isSearching = false
                }
            }
        }
        searchWork = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func restore(_ receipt: TrashReceipt, event: CleanupEvent) {
        guard !isCleaning, !restoringItems.contains(receipt.id) else { return }
        if isScanning { cancelScan() }
        restoringItems.insert(receipt.id); isCleaning = true; cleaningLabel = "Restoring…"
        let persistence = store
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CleanupService(allowedRoots: [receipt.originalURL.deletingLastPathComponent()]).restore(receipt)
                var updated = event
                updated.restored.append(receipt.id)
                var saveError: String?
                do { try persistence?.saveHistory(updated) } catch { saveError = error.localizedDescription }
                let history = (try? persistence?.history()) ?? []
                let warning = saveError
                DispatchQueue.main.async {
                    self.restoringItems.remove(receipt.id); self.isCleaning = false
                    self.cleanupHistory = history
                    self.notice = "Restored \(receipt.originalURL.lastPathComponent) to its original location."
                    if let warning { self.persistenceWarning = warning }
                    self.runFullScan()
                }
            } catch {
                DispatchQueue.main.async {
                    self.restoringItems.remove(receipt.id); self.isCleaning = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func clearSavedScans() {
        guard !isScanning, !isCleaning, let store else { return }
        snapshotLoadID = UUID(); stopDuplicateSearch(); duplicateGroups = []; duplicateHasRun = false
        stopBrowserWork(); insightID = UUID(); isCleaning = true; cleaningLabel = "Clearing saved indexes…"
        DispatchQueue.global(qos: .utility).async {
            do {
                try store.clearScans()
                DispatchQueue.main.async {
                    self.isCleaning = false
                    self.snapshot = nil; self.previousSnapshot = nil; self.savedSnapshots = []
                    self.clearDirectoryCache(); self.resetMapCache(); self.showingSavedScan = false
                    self.categoryTotals = []; self.largestFiles = []; self.changes = []; self.searchResults = []; self.mapEntries = []
                    self.localIndexBytes = store.localDataBytes()
                    self.notice = "Saved indexes cleared. Refresh a scan to rebuild search and saved browsing. Cleanup history was kept."
                }
            } catch { DispatchQueue.main.async { self.isCleaning = false; self.errorMessage = error.localizedDescription } }
        }
    }

    func exportReport() {
        guard let snapshot else { notice = "Complete a folder scan before exporting a report."; return }
        struct Report: Encodable {
            let generatedAt: Date
            let snapshot: ScanSnapshot
            let volume: DiskOverview
            let categories: [CategoryTotal]
            let largestFiles: [CatalogEntry]
            let changes: [ScanChange]
            let note: String
        }
        let report = Report(generatedAt: Date(), snapshot: snapshot, volume: overview, categories: categoryTotals, largestFiles: largestFiles, changes: changes,
            note: "Allocated storage, not guaranteed reclaimable space. Inaccessible entries are omitted; compare coverage counts before interpreting changes.")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "LintGoblin-Report.json"
        panel.message = "Save a local storage report. It includes file paths."
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(report).write(to: url, options: .atomic)
                    DispatchQueue.main.async { self?.notice = "Report saved to \(url.lastPathComponent)." }
                } catch { DispatchQueue.main.async { self?.errorMessage = error.localizedDescription } }
            }
        }
        if let window = NSApplication.shared.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
