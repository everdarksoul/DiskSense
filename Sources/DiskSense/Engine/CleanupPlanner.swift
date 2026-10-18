import Foundation

/// A proposal, never a deletion instruction. CleanupService revalidates every
/// selected path when the user opens the separate cleanup review.
struct CleanupPlan {
    let goalBytes: Int64
    let candidates: [JunkItem]
    let proposedBytes: Int64
    let sourceSignature: [CleanupPlanner.SourceItem]

    var reachesGoal: Bool { proposedBytes >= goalBytes }
    var shortfallBytes: Int64 { max(0, goalBytes - proposedBytes) }
}

enum CleanupPlanner {
    struct SourceItem: Hashable {
        let path: String
        let name: String
        let bytes: Int64
        let kind: String
        let note: String
    }

    static func signature(of items: [JunkItem]) -> [SourceItem] {
        items.map { SourceItem(path: $0.path, name: $0.name, bytes: $0.bytes, kind: $0.kind.rawValue, note: $0.note) }
            .sorted {
                [$0.path, $0.name, String($0.bytes), $0.kind, $0.note]
                    .lexicographicallyPrecedes([$1.path, $1.name, String($1.bytes), $1.kind, $1.note])
            }
    }

    /// Only cache and generated build data participate. Logs, state, leftovers,
    /// receipts, containers, Trash and personal files are deliberately excluded.
    static func eligibleCandidates(from items: [JunkItem]) -> [JunkItem] {
        let sorted = items.filter { item in
            guard item.bytes > 0, item.path.hasPrefix("/"), normalized(item.path) != "/" else { return false }
            switch item.kind {
            case .systemCache, .devCache, .buildArtifacts: return true
            default: return false
            }
        }
            .sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                if normalized($0.path) != normalized($1.path) { return normalized($0.path) < normalized($1.path) }
                if $0.name != $1.name { return $0.name < $1.name }
                if $0.note != $1.note { return $0.note < $1.note }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        var unique: [String: JunkItem] = [:]
        for item in sorted {
            let path = normalized(item.path)
            if unique[path] == nil { unique[path] = item }
        }
        // Keep the enclosing candidate even when a stale child measurement is
        // larger, so overlapping folder totals can never be counted twice.
        let paths = Set(unique.keys)
        return unique.filter { path, _ in
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
            while parent != "/" {
                if paths.contains(parent) { return false }
                let next = URL(fileURLWithPath: parent).deletingLastPathComponent().path
                if next == parent { break }
                parent = next
            }
            return !paths.contains("/") || path == "/"
        }.values.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return normalized($0.path) < normalized($1.path)
        }
    }

    static func makePlan(from items: [JunkItem], goalBytes: Int64) -> CleanupPlan {
        let goal = max(0, goalBytes)
        var proposed: [JunkItem] = []
        var bytes: Int64 = 0
        if goal > 0 {
            for item in eligibleCandidates(from: items) {
                proposed.append(item)
                bytes = adding(bytes, item.bytes)
                if bytes >= goal { break }
            }
        }
        return CleanupPlan(goalBytes: goal, candidates: proposed, proposedBytes: bytes, sourceSignature: signature(of: items))
    }

    static func totalBytes(_ items: [JunkItem]) -> Int64 {
        items.reduce(0) { adding($0, max(0, $1.bytes)) }
    }

    private static func normalized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    private static func adding(_ left: Int64, _ right: Int64) -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        return overflow ? Int64.max : value
    }
}
