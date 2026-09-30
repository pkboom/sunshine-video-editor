import Foundation

public enum ProtectedFolder: Sendable { case downloads, desktop, documents }

/// File errors classified for display: a permission failure inside a TCC-protected
/// folder means the user denied (or never granted) folder access.
public enum FileAccessError: Error, Equatable {
    case tccDenied(ProtectedFolder)
    case generic(String)

    public static func classify(_ error: Error, path: URL) -> FileAccessError {
        classify(error, path: path, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func classify(_ error: Error, path: URL, home: URL) -> FileAccessError {
        if isPermissionError(error as NSError), let folder = protectedFolder(containing: path, home: home) {
            return .tccDenied(folder)
        }
        return .generic(error.localizedDescription)
    }

    private static func isPermissionError(_ e: NSError) -> Bool {
        switch e.domain {
        case NSCocoaErrorDomain where e.code == NSFileWriteNoPermissionError || e.code == NSFileReadNoPermissionError:
            return true
        case NSPOSIXErrorDomain where e.code == Int(EPERM) || e.code == Int(EACCES):
            return true
        default:
            if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
            return false
        }
    }

    private static func protectedFolder(containing path: URL, home: URL) -> ProtectedFolder? {
        let target = path.standardizedFileURL.pathComponents
        let folders: [(String, ProtectedFolder)] = [("Downloads", .downloads), ("Desktop", .desktop), ("Documents", .documents)]
        for (name, folder) in folders {
            let root = home.appendingPathComponent(name, isDirectory: true).standardizedFileURL.pathComponents
            if target.count >= root.count, Array(target.prefix(root.count)) == root { return folder }
        }
        return nil
    }
}
