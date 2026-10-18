import Foundation

protocol JunkScanning {
    func cancel()
    func detect(onProgress: @escaping (String) -> Void,
                completion: @escaping ([JunkItem], Int) -> Void)
}

extension JunkScanning {
    func cancel() {}
}

/// Surfaces specific user-owned caches and build output for review. App data,
/// simulator devices, installer receipts and guessed "orphans" are not junk.
final class JunkDetector: JunkScanning {
    private let fm = FileManager.default
    private let home: URL
    private let scanner = DiskScanner()
    private let workLock = NSLock()
    private var currentWork: EngineScanToken?

    func cancel() {
        workLock.lock(); defer { workLock.unlock() }
        currentWork?.cancel()
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    private struct Rule {
        let path: String
        let kind: JunkItem.Kind
        let note: String
    }

    private var rules: [Rule] {
        [
            Rule(path: "Library/Developer/Xcode/DerivedData", kind: .buildArtifacts,
                 note: "Generated Xcode build output. Close Xcode first; projects will rebuild."),
            Rule(path: ".npm/_cacache", kind: .devCache,
                 note: "Downloaded npm packages. Future installs may download them again."),
            Rule(path: ".cache/yarn", kind: .devCache,
                 note: "Downloaded Yarn packages. Future installs may download them again."),
            Rule(path: ".cargo/registry/cache", kind: .devCache,
                 note: "Downloaded Rust crates. Future builds may download them again."),
            Rule(path: ".gradle/caches", kind: .devCache,
                 note: "Gradle build caches. Close build tools first; subsequent builds may be slower.")
        ]
    }

    func detect(onProgress: @escaping (String) -> Void,
                completion: @escaping ([JunkItem], Int) -> Void) {
        let token = EngineScanToken()
        workLock.lock()
        currentWork?.cancel()
        currentWork = token
        workLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            var items: [JunkItem] = []
            var unreadable = 0
            var seen = Set<String>()
            func measure(_ url: URL, kind: JunkItem.Kind, note: String) {
                guard !token.isCancelled, seen.insert(url.path).inserted,
                      let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                      values.isSymbolicLink != true else { return }
                DispatchQueue.main.async { if !token.isCancelled { onProgress("Measuring \(url.lastPathComponent)…") } }
                let result = self.scanner.measure(at: url, isCancelled: { token.isCancelled })
                unreadable += result.unreadable
                if result.bytes > 0 {
                    items.append(JunkItem(name: url.lastPathComponent, path: url.path,
                                          bytes: result.bytes, kind: kind, note: note))
                }
            }
            for rule in self.rules {
                measure(self.home.appendingPathComponent(rule.path), kind: rule.kind, note: rule.note)
            }
            // Separate cache entries preserve selection and prevent overlapping
            // totals (e.g. Caches and Caches/Homebrew counted twice).
            let caches = self.home.appendingPathComponent("Library/Caches")
            do {
                for entry in try self.fm.contentsOfDirectory(at: caches,
                    includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
                    measure(entry, kind: .systemCache,
                            note: "User cache. Close the associated app first; it may recreate this data.")
                }
            } catch {
                if self.fm.fileExists(atPath: caches.path) { unreadable += 1 }
            }
            guard !token.isCancelled else { return }
            items.sort { $0.bytes > $1.bytes }
            let result = items
            let unreadableCount = unreadable
            DispatchQueue.main.async { if !token.isCancelled { completion(result, unreadableCount) } }
        }
    }
}
