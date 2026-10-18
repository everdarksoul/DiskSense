import Foundation

extension AppModel {
    var canGoBack: Bool { navigationIndex > 0 }
    var canGoForward: Bool { navigationIndex + 1 < navigationHistory.count }
    var explorerURL: URL { selection == .browser ? browserURL : mapURL }

    func rememberLocation(_ url: URL) {
        guard !restoringNavigation else { return }
        if navigationHistory.indices.contains(navigationIndex), navigationHistory[navigationIndex] == url { return }
        navigationHistory = Array(navigationHistory.prefix(navigationIndex + 1))
        navigationHistory.append(url)
        if navigationHistory.count > 100 { navigationHistory.removeFirst() }
        navigationIndex = navigationHistory.count - 1
    }
    func goBack() { goHistory(-1) }
    func goForward() { goHistory(1) }
    private func goHistory(_ offset: Int) {
        let next = navigationIndex + offset
        guard navigationHistory.indices.contains(next) else { return }
        navigationIndex = next; restoringNavigation = true
        let url = navigationHistory[next]
        if selection == .browser { browse(url) } else { loadMap(url) }
        restoringNavigation = false
    }
    func switchExplorer(to tab: SidebarTab) {
        let url = explorerURL
        if tab == .browser { browse(url) }
        else { selection = .spaceMap; loadMap(url) }
    }
    func cacheMap(_ entries: [CatalogEntry], at url: URL, measuredAt: Date? = nil) {
        mapCache[url.path] = entries
        mapDates[url.path] = measuredAt ?? snapshot?.finished ?? Date()
        mapCacheOrder.removeAll { $0 == url.path }; mapCacheOrder.append(url.path)
        while mapCacheOrder.count > 24 || mapCache.values.reduce(0, { $0 + $1.count }) > 50_000 {
            guard let oldest = mapCacheOrder.first else { break }
            mapCacheOrder.removeFirst(); mapCache.removeValue(forKey: oldest); mapDates.removeValue(forKey: oldest)
        }
    }
    func resetMapCache() {
        mapCache = [:]; mapCacheOrder = []; mapDates = [:]; mapMeasuredAt = nil; mapError = nil
        mapCancellation.cancel(); mapCancellation = ScanCancellation()
    }
    func refreshFolder() { runFullScan(includeInventories: false) }
}
