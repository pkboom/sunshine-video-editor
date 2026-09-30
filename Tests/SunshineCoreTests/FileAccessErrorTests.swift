import Foundation
import Testing
@testable import SunshineCore

@Suite struct FileAccessErrorTests {
    let home = FileManager.default.homeDirectoryForCurrentUser

    func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

    @Test func epermUnderDownloadsIsTCC() {
        let path = home.appendingPathComponent("Downloads/clip.mp4")
        #expect(FileAccessError.classify(posix(EPERM), path: path) == .tccDenied(.downloads))
    }

    @Test func epermUnderTmpIsGeneric() {
        let result = FileAccessError.classify(posix(EPERM), path: URL(fileURLWithPath: "/tmp/clip.mp4"))
        guard case .generic = result else { Issue.record("expected generic, got \(result)"); return }
    }

    @Test func eaccesUnderDocumentsIsTCC() {
        let path = home.appendingPathComponent("Documents/a/b/clip.mov")
        #expect(FileAccessError.classify(POSIXError(.EACCES), path: path) == .tccDenied(.documents))
    }

    @Test func cocoaWriteNoPermissionUnderDesktopIsTCC() {
        let path = home.appendingPathComponent("Desktop/clip-edited.mp4")
        #expect(FileAccessError.classify(CocoaError(.fileWriteNoPermission), path: path) == .tccDenied(.desktop))
        #expect(FileAccessError.classify(CocoaError(.fileReadNoPermission), path: path) == .tccDenied(.desktop))
    }

    @Test func underlyingPOSIXErrorIsUnwrapped() {
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: posix(EPERM)])
        let path = home.appendingPathComponent("Downloads/x.mp4")
        #expect(FileAccessError.classify(wrapped, path: path) == .tccDenied(.downloads))
    }

    @Test func nonPermissionErrorIsGeneric() {
        let path = home.appendingPathComponent("Downloads/clip.mp4")
        let error = CocoaError(.fileNoSuchFile)
        #expect(FileAccessError.classify(error, path: path) == .generic(error.localizedDescription))
    }

    @Test func similarlyNamedFolderIsNotProtected() {
        let path = home.appendingPathComponent("DownloadsArchive/clip.mp4")
        guard case .generic = FileAccessError.classify(posix(EPERM), path: path) else {
            Issue.record("DownloadsArchive must not match Downloads"); return
        }
    }

    @Test func injectedHomeIsUsed() {
        let other = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let path = URL(fileURLWithPath: "/Users/tester/Downloads/../Desktop/clip.mp4")
        #expect(FileAccessError.classify(posix(EPERM), path: path, home: other) == .tccDenied(.desktop))
    }
}
