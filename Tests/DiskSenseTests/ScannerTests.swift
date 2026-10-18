import Foundation
import Testing
import Darwin
@testable import DiskSense

struct ScannerTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSense-Scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ url: URL, bytes: Int = 131_072) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x65, count: bytes).write(to: url)
    }

    @Test func includesHiddenFilesAndPackageContents() throws {
        try fixture { root in
            try write(root.appendingPathComponent(".hidden/data"))
            try write(root.appendingPathComponent("Example.app/Contents/MacOS/program"), bytes: 262_144)
            let scanner = DiskScanner()
            let result = scanner.scanDirectory(at: root)
            #expect(result.children.count == 2)
            #expect(result.unreadable == 0)
            #expect(!result.cancelled)
            #expect(result.children.first?.name == "Example.app")
            #expect(result.children.allSatisfy { $0.bytes >= 131_072 })
            #expect(result.bytes == scanner.measure(at: root).bytes)
            #expect(result.bytes == scanner.sweep(root: root, onProgress: { _ in }).bytes)
        }
    }

    @Test func symbolicLinksDoNotFollowOutsideTargetsOrCycles() throws {
        try fixture { root in
            let directory = root.appendingPathComponent("folder")
            try write(directory.appendingPathComponent("data"))
            let scanner = DiskScanner()
            let before = scanner.measure(at: directory).bytes
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("cycle"), withDestinationURL: root)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("external"), withDestinationURL: URL(fileURLWithPath: "/"))
            let result = scanner.scanDirectory(at: directory)
            #expect(result.children.count == 3)
            #expect(result.children.filter { $0.name != "data" }.allSatisfy { !$0.isDirectory && $0.bytes < before })
            #expect(result.bytes < before + 131_072)
            #expect(result.unreadable == 0)
        }
    }

    @Test func countsHardLinkedFileAllocationOnceAcrossChildren() throws {
        try fixture { root in
            let original = root.appendingPathComponent("a")
            try write(original, bytes: 524_288)
            try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("b"))
            let result = DiskScanner().scanDirectory(at: root)
            #expect(result.children.map(\.bytes).reduce(0, +) == DiskScanner().measure(at: original).bytes)
            #expect(result.children.filter { $0.bytes == 0 }.count == 1)
        }
    }

    @Test func sparseFileUsesAllocatedRatherThanLogicalSize() throws {
        try fixture { root in
            let file = root.appendingPathComponent("sparse")
            #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 128 * 1_024 * 1_024)
            #expect(DiskScanner().measure(at: file).bytes < 1_024 * 1_024)
        }
    }

    @Test func missingRootReportsFailure() throws {
        try fixture { root in
            let missing = root.appendingPathComponent("missing")
            let result = DiskScanner().scanDirectory(at: missing)
            #expect(result.unreadable == 1)
            #expect(result.children.isEmpty)
            #expect(DiskScanner().measure(at: missing).unreadable == 1)
        }
    }

    @Test func inaccessibleDirectoryReportsSkippedContents() throws {
        guard geteuid() != 0 else { return }
        try fixture { root in
            let locked = root.appendingPathComponent("locked")
            try write(locked.appendingPathComponent("data"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
            let result = DiskScanner().scanDirectory(at: root)
            #expect(result.unreadable >= 1)
            #expect(result.children.first?.unreadable ?? 0 >= 1)
        }
    }

    @Test func cancellationStopsBeforeNextChildAndReturnsPartialResults() throws {
        try fixture { root in
            for number in 0..<5 { try write(root.appendingPathComponent("file-\(number)")) }
            var cancelled = false
            var delivered = 0
            let result = DiskScanner().scanDirectory(at: root, isCancelled: { cancelled }, onEntry: { _ in
                delivered += 1
                cancelled = true
            })
            #expect(result.cancelled)
            #expect(delivered == 1)
            #expect(result.children.count == 1)
            let preCancelled = DiskScanner().scanDirectory(at: root, isCancelled: { true })
            #expect(preCancelled.cancelled)
            #expect(preCancelled.children.isEmpty)
        }
    }

    @Test func throttlesProgressWithoutDroppingCompletedEntries() throws {
        try fixture { root in
            for number in 0..<100 { try write(root.appendingPathComponent("file-\(number)"), bytes: 32) }
            var progressCount = 0
            var delivered = 0
            let start = ProcessInfo.processInfo.systemUptime
            let result = DiskScanner().scanDirectory(at: root, onProgress: { _ in progressCount += 1 }, onEntry: { _ in delivered += 1 })
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            #expect(delivered == 100)
            #expect(result.children.count == 100)
            #expect(progressCount >= 1)
            #expect(progressCount <= Int(elapsed / 0.1) + 1)
        }
    }
}
