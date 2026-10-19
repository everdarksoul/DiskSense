import Foundation
import Testing
@testable import DiskSense

struct LargeDirectoryTests {
    @Test func scanAndIndexedReadOfFiveThousandFiles() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("Tree")
        defer { try? fm.removeItem(at: fixture) }
        let payload = Data(repeating: 41, count: 1024)
        for directory in 0..<50 {
            let folder = root.appendingPathComponent("Folder-\(directory)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in 0..<100 { try payload.write(to: folder.appendingPathComponent("\(file).dat")) }
        }
        let store = try ScanStore(directory: fixture.appendingPathComponent("Store"))
        let start = ProcessInfo.processInfo.systemUptime
        let writer = try store.begin(root: root)
        let result = DiskScanner().scanDirectory(at: root, catalog: writer)
        let saved = try writer.complete(bytes: result.bytes, unreadable: result.unreadable)
        let scanTime = ProcessInfo.processInfo.systemUptime - start
        let readStart = ProcessInfo.processInfo.systemUptime
        let rows = try store.children(snapshot: saved.id, parent: root.appendingPathComponent("Folder-25").path)
        let readTime = ProcessInfo.processInfo.systemUptime - readStart
        #expect(saved.entryCount == 5051)
        #expect(saved.indexTruncated == false)
        #expect(result.children.count == 50 && result.unreadable == 0)
        #expect(rows.count == 100)
        print(String(format: "BENCHMARK 5000 files: indexed scan %.3fs; 100-row indexed folder %.4fs", scanTime, readTime))
    }
    @Test func completeIndexSurvivesTheFormerFileCountAndPathBudgets() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("Tree")
        let store = try ScanStore(directory: fixture.appendingPathComponent("Store"))
        let writer = try store.begin(root: root)
        let start = ProcessInfo.processInfo.systemUptime
        let longComponent = String(repeating: "nested-", count: 18)
        let nested = root.appendingPathComponent(longComponent).appendingPathComponent(longComponent).appendingPathComponent("Late files")
        let total = 200_005
        // Metadata fixtures deliberately exceed both former cutoffs without
        // creating hundreds of thousands of real files on a developer's disk.
        for index in 0..<total {
            let name = "sample-\(index).bin"
            writer.record(CatalogEntry(path: nested.appendingPathComponent(name).path, parent: nested.path, name: name, isDirectory: false, isPackage: false, bytes: Int64(index), logicalBytes: index >= total - 2 ? 2_000_000 : Int64(index), modified: Date(timeIntervalSince1970: 1), unreadable: 0, category: .other, isSymbolicLink: false))
        }
        let saved = try writer.complete(bytes: 123, unreadable: 0)
        #expect(saved.entryCount == total)
        #expect(saved.indexTruncated == false)
        #expect(try store.children(snapshot: saved.id, parent: nested.path).count == total)
        #expect(try store.search(snapshot: saved.id, text: "sample-200004.bin").first?.path == nested.appendingPathComponent("sample-200004.bin").path)
        #expect(try store.search(snapshot: saved.id, text: "Late files/sample-200004").count == 1)
        #expect(try store.duplicateCandidates(snapshot: saved.id).count == 2)
        try store.maintain()
        let reopened = try ScanStore(directory: fixture.appendingPathComponent("Store"))
        #expect(try reopened.snapshots().first?.entryCount == total)
        #expect(try reopened.search(snapshot: saved.id, text: "sample-200004.bin").count == 1)
        print(String(format: "BENCHMARK 200005 long-path entries: %.3fs; complete index %.1f MiB", ProcessInfo.processInfo.systemUptime - start, Double(store.localDataBytes()) / 1048576))
        #expect(store.localDataBytes() < 80 * 1024 * 1024)
    }

}
