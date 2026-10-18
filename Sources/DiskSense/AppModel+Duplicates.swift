import Foundation

extension AppModel {
    func stopDuplicateSearch() {
        duplicateToken.cancel(); duplicateID = UUID(); duplicateIsScanning = false
    }

    func findDuplicates() {
        guard !isScanning, !isCleaning, let snapshot, let store else { return }
        stopDuplicateSearch()
        let token = ScanCancellation(); duplicateToken = token
        duplicateID = UUID(); let request = duplicateID
        duplicateGroups = []; duplicateHasRun = false; duplicateSkipped = 0
        duplicateError = nil; duplicateIsScanning = true; duplicateProgress = "Finding matching file sizes…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try store.duplicateCandidates(snapshot: snapshot.id)
                if token.isCancelled { return }
                let result = DuplicateFinder.find(entries: entries, isCancelled: { token.isCancelled }, onProgress: { path in
                    DispatchQueue.main.async {
                        guard self.duplicateID == request else { return }
                        self.duplicateProgress = path
                    }
                })
                DispatchQueue.main.async {
                    guard self.duplicateID == request, self.snapshot?.id == snapshot.id else { return }
                    self.duplicateGroups = result.groups; self.duplicateSkipped = result.skipped
                    self.duplicateHasRun = !result.cancelled; self.duplicateIsScanning = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.duplicateID == request else { return }
                    self.duplicateIsScanning = false; self.duplicateError = error.localizedDescription
                }
            }
        }
    }

    func reviewDuplicates(_ entries: [CatalogEntry]) {
        guard !isScanning, !isCleaning, !duplicateIsScanning, !entries.isEmpty else { return }
        let groups = duplicateGroups
        isCleaning = true; cleaningLabel = "Checking duplicate copies…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let checked = try DuplicateFinder.validateForCleanup(entries: entries, groups: groups)
                DispatchQueue.main.async {
                    self.isCleaning = false
                    self.reviewCleanup(checked)
                    guard self.showingCleanup else { return }
                    self.cleanupDuplicateGroups = groups
                    // Cleanup canonicalizes startup Data aliases; map reviewed
                    // rows back to their verified entries by filesystem identity.
                    self.cleanupDuplicateEntries = Dictionary(uniqueKeysWithValues: self.cleanupCandidates.compactMap { candidate in
                        guard let matched = checked.first(where: { $0.expectedIdentity == candidate.expectedIdentity }),
                              let entry = entries.first(where: { $0.path == matched.url.path }) else { return nil }
                        return (candidate.id, entry)
                    })
                }
            } catch { DispatchQueue.main.async { self.isCleaning = false; self.errorMessage = error.localizedDescription } }
        }
    }
}
