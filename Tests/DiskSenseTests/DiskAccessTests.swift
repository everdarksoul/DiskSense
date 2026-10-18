import Foundation
import Testing
@testable import DiskSense

struct DiskAccessTests {
    @Test func successfulDirectoryReadConfirmsAccess() {
        #expect(FullDiskAccess.status(checkDirectory: { _ in }) == .accessible)
    }

    @Test func missingDirectoriesDoNotClaimPermissionWasDenied() {
        #expect(FullDiskAccess.status(checkDirectory: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        }) == .unknown)
    }

    @Test func accessDenialsAreRecognized() {
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))] {
            #expect(FullDiskAccess.status(checkDirectory: { _ in throw error }) == .denied)
        }
    }

    @Test func missingMailFolderFallsBackToMessages() {
        #expect(FullDiskAccess.status(checkDirectory: { url in
            if url.lastPathComponent == "Mail" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
            }
        }) == .accessible)
    }
}
