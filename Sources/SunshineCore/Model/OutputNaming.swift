import Foundation

/// Export file names: `<stem>-edited.mp4`, then `<stem>-edited-1.mp4`, … next to the source.
public enum OutputNaming {
    /// n = 0 → `<stem>-edited.mp4`; n ≥ 1 → `<stem>-edited-<n>.mp4`. Always `.mp4`.
    public static func candidate(source: URL, n: Int) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let name = n == 0 ? "\(stem)-edited.mp4" : "\(stem)-edited-\(n).mp4"
        return source.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    /// The first candidate for which `exists` is false.
    public static func firstFree(source: URL, exists: (URL) -> Bool) -> URL {
        var n = 0
        while exists(candidate(source: source, n: n)) { n += 1 }
        return candidate(source: source, n: n)
    }
}
