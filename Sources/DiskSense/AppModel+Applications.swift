import AppKit
import Foundation

extension AppModel {
    func isRunning(_ app: AppEntry) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.resolvingSymlinksInPath().path == app.appURL.resolvingSymlinksInPath().path }
    }
    func requestQuit(_ app: AppEntry) {
        guard app.appURL.resolvingSymlinksInPath().path != Bundle.main.bundleURL.resolvingSymlinksInPath().path else { return }
        let processes = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path == app.appURL.resolvingSymlinksInPath().path }
        let accepted = processes.allSatisfy { $0.terminate() }
        notice = accepted ? "Requested that \(app.name) quit normally. Save any open work in that app, then review its connected files. Other apps can stay open." : "\(app.name) did not accept the quit request. Quit it yourself after saving your work."
    }
    func reviewConnections(app: AppEntry, paths: Set<String>) {
        let candidates = ([CleanupCandidate(url: app.appURL, bytes: app.allocatedBytes, reason: "Application bundle")] + app.relatedFiles.map {
            CleanupCandidate(url: URL(fileURLWithPath: $0.path), bytes: $0.bytes, reason: "Possible related \($0.category.rawValue.lowercased()) for \(app.name) — verify this match")
        }).filter { paths.contains($0.id) }
        reviewCleanup(candidates, associatedAppURL: app.appURL)
    }
}

extension RelatedFile {
    var managedService: Bool {
        ["/Library/LaunchAgents/", "/Library/LaunchDaemons/", "/Library/PrivilegedHelperTools/"].contains { path.hasPrefix($0) }
    }
    var caution: String {
        if managedService { return "Managed service · inspect in Finder; privileged removal is unavailable in this beta" }
        switch category {
        case .applicationSupport, .containers: return "May contain documents, databases, settings or accounts"
        case .groupContainers: return "May be shared with other apps; verify ownership before selecting"
        case .caches, .logs: return "Generated data; the app may recreate it"
        default: return "Name or bundle-identifier match; verify before removing"
        }
    }
}
