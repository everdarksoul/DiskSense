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
}
