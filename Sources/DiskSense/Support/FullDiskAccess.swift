import Foundation
import AppKit

/// Detects Full Disk Access state and deep-links to the privacy pane
/// (the OmniDiskSweeper trick we found in its binary).
enum FullDiskAccess {
    enum Status { case accessible, denied, unknown }

    /// Test an actual directory read; a metadata readability check cannot
    /// reliably establish whether macOS permits access to protected data.
    /// Missing folders and other I/O errors do not imply a denied permission.
    static func status(checkDirectory: (URL) throws -> Void = { url in
        _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
    }) -> Status {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in ["Library/Mail", "Library/Messages"] {
            do {
                try checkDirectory(home.appendingPathComponent(path))
                return .accessible
            } catch {
                let error = error as NSError
                if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                    || (error.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(error.code)) {
                    return .denied
                }
            }
        }
        return .unknown
    }

    /// Deep-link straight to System Settings ▸ Privacy ▸ Full Disk Access.
    static func openPrivacyPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
