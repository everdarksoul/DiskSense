import Foundation

protocol AppInventoryScanning {
    func cancel()
    func buildInventory(onProgress: @escaping (String) -> Void,
                        completion: @escaping ([AppEntry]) -> Void)
}

extension AppInventoryScanning {
    func cancel() {}
}

/// A scan owns its token, so stopping a scan cannot cancel a later rescan.
final class EngineScanToken {
    private let lock = NSLock()
    private var stopped = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

/// Builds a read-only inventory. Related files are review candidates: matching a
/// bundle identifier does not establish that another app never uses that file.
final class AppInventory: AppInventoryScanning {
    private let fm = FileManager.default
    private let home: URL
    private let roots: [URL]
    private let scanner = DiskScanner()
    private let workLock = NSLock()
    private var currentWork: EngineScanToken?

    func cancel() {
        workLock.lock(); defer { workLock.unlock() }
        currentWork?.cancel()
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, appRoots: [URL]? = nil) {
        self.home = home
        self.roots = appRoots ?? [URL(fileURLWithPath: "/Applications"),
                                 URL(fileURLWithPath: "/System/Applications"),
                                 home.appendingPathComponent("Applications")]
    }

    private struct Candidate {
        let url: URL
        let category: RelatedFile.Category
    }

    private var whitelist: [(URL, RelatedFile.Category)] {
        let user: [(String, RelatedFile.Category)] = [
            ("Library/Preferences", .preferences), ("Library/Caches", .caches),
            ("Library/Application Support", .applicationSupport), ("Library/Containers", .containers),
            ("Library/Group Containers", .groupContainers), ("Library/Saved Application State", .savedState),
            ("Library/Logs", .logs), ("Library/LaunchAgents", .launchAgents),
            ("Library/HTTPStorages", .caches), ("Library/WebKit", .caches)
        ]
        let global: [(String, RelatedFile.Category)] = [
            ("/Library/Application Support", .applicationSupport), ("/Library/Preferences", .preferences),
            ("/Library/Caches", .caches), ("/Library/Logs", .logs),
            ("/Library/LaunchAgents", .launchAgents), ("/Library/LaunchDaemons", .launchDaemons),
            ("/Library/PrivilegedHelperTools", .other)
        ]
        // Managed services are reveal-only in the UI. Installer receipts and
        // protected OS trees are not treated as uninstall leftovers.
        return user.map { (home.appendingPathComponent($0.0), $0.1) } + global.map { (URL(fileURLWithPath: $0.0), $0.1) }
    }

    func buildInventory(onProgress: @escaping (String) -> Void,
                        completion: @escaping ([AppEntry]) -> Void) {
        let token = EngineScanToken()
        workLock.lock()
        currentWork?.cancel()
        currentWork = token
        workLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let report: (String) -> Void = { message in
                DispatchQueue.main.async { if !token.isCancelled { onProgress(message) } }
            }
            // Read each candidate directory once, rather than once per app.
            let candidates = self.whitelist.flatMap { directory, category -> [Candidate] in
                guard !token.isCancelled else { return [] }
                let entries = (try? self.fm.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])) ?? []
                return entries.filter {
                    (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
                }.map { Candidate(url: $0, category: category) }
            }
            var sizes: [String: Int64] = [:]
            var apps: [AppEntry] = []
            for url in self.applicationURLs(isCancelled: { token.isCancelled }) {
                guard !token.isCancelled else { return }
                let info = self.bundleInfo(for: url)
                report("Measuring \(info.name)…")
                var app = AppEntry(name: info.name, bundleIdentifier: info.bundleID, appURL: url,
                                   allocatedBytes: self.scanner.measure(at: url, isCancelled: { token.isCancelled }).bytes, version: info.version)
                app.relatedFiles = candidates.compactMap { candidate in
                    guard !token.isCancelled, Self.matches(filename: candidate.url.lastPathComponent,
                                       bundleID: info.bundleID, appName: info.name) else { return nil }
                    let path = candidate.url.path
                    let bytes: Int64
                    if let cached = sizes[path] { bytes = cached }
                    else { bytes = self.scanner.measure(at: candidate.url, isCancelled: { token.isCancelled }).bytes; sizes[path] = bytes }
                    return RelatedFile(path: path, bytes: bytes, category: candidate.category)
                }.sorted { $0.bytes > $1.bytes }
                apps.append(app)
            }
            apps.sort { $0.allocatedBytes > $1.allocatedBytes }
            let result = apps
            DispatchQueue.main.async { if !token.isCancelled { completion(result) } }
        }
    }

    private func applicationURLs(isCancelled: () -> Bool) -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        func visit(_ directory: URL, depth: Int) {
            guard !isCancelled(), depth < 5, let entries = try? fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles]) else { return }
            for entry in entries {
                guard !isCancelled() else { return }
                guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
                      values.isSymbolicLink != true else { continue }
                if entry.pathExtension.lowercased() == "app" {
                    if seen.insert(entry.standardizedFileURL.path).inserted { found.append(entry) }
                } else if values.isDirectory == true && values.isPackage != true {
                    visit(entry, depth: depth + 1)
                }
            }
        }
        for root in roots { visit(root, depth: 0) }
        return found.sorted { $0.path < $1.path }
    }

    private func bundleInfo(for url: URL) -> (name: String, bundleID: String?, version: String?) {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: infoURL)).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
        } ?? [:]
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return (name, info["CFBundleIdentifier"] as? String, info["CFBundleShortVersionString"] as? String)
    }

    static func matches(filename: String, bundleID: String?, appName: String) -> Bool {
        let lower = filename.lowercased()
        if let id = bundleID?.lowercased(), !id.isEmpty,
           lower == id || lower.hasPrefix(id + ".") { return true }
        // Whole-name matches only: "Code" must never claim "Xcode" or
        // unrelated preferences containing the word code.
        var base = lower
        for suffix in [".plist", ".savedstate", ".log"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        func normalized(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let name = normalized(appName)
        return name.count >= 3 && normalized(base) == name
    }

    func allocatedSize(of url: URL) -> Int64 {
        scanner.measure(at: url).bytes
    }
}
