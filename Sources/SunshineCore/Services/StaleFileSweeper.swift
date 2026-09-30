import Foundation

/// Removes leftovers that only Sunshine creates, matched by exact name shape. Never globs
/// arbitrary files in Downloads or next to the source.
public enum StaleFileSweeper {
    public static let downloadTempPrefix = ".sunshine-dl-"
    public static let partialSuffix = ".sunshine-partial.mp4"
    /// Partial exports younger than this may belong to another running Sunshine.
    public static let partialMaxAge: TimeInterval = 60 * 60

    /// At launch: removes `<Downloads>/.sunshine-dl-<uuid>/` directories (no download runs yet).
    public static func sweepDownloads() {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        sweepDownloads(in: downloads)
    }

    /// On open: removes `.<stem>.<uuid>.sunshine-partial.mp4` next to `source` that are older than
    /// 1 h and aren't `activeExportPartial`.
    public static func sweepPartials(nextTo source: URL, activeExportPartial: URL?) {
        sweepPartials(nextTo: source, activeExportPartial: activeExportPartial, now: Date())
    }

    static func sweepDownloads(in downloads: URL) {
        for url in contents(of: downloads) {
            let name = url.lastPathComponent
            guard name.hasPrefix(downloadTempPrefix),
                  UUID(uuidString: String(name.dropFirst(downloadTempPrefix.count))) != nil,
                  isDirectory(url) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func sweepPartials(nextTo source: URL, activeExportPartial: URL?, now: Date) {
        let stem = source.deletingPathExtension().lastPathComponent
        let prefix = ".\(stem)."
        let active = activeExportPartial?.standardizedFileURL.path
        for url in contents(of: source.deletingLastPathComponent()) {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(partialSuffix),
                  name.count > prefix.count + partialSuffix.count else { continue }
            let middle = name.dropFirst(prefix.count).dropLast(partialSuffix.count)
            guard UUID(uuidString: String(middle)) != nil,
                  url.standardizedFileURL.path != active,
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > partialMaxAge else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func contents(of dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
