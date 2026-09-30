import AVFoundation
import Foundation
import Synchronization

public enum ExportUpdate: Sendable, Equatable {
    case progress(Double)
    case completed(URL)
}

public enum ExportError: Error, Equatable, LocalizedError {
    case incompatible
    case alreadyExporting
    case noFreeName

    public var errorDescription: String? {
        switch self {
        case .incompatible: "This source can't be saved losslessly as MP4."
        case .alreadyExporting: "An export is already running."
        case .noFreeName: "Couldn't find a free output name next to the source."
        }
    }
}

/// Lossless passthrough export of a frozen composition to `<stem>-edited[-N].mp4` beside the source.
///
/// The composition is written to a unique hidden partial file first and then moved to the first free
/// output name. Existing files are never overwritten.
public actor ExportService {
    public typealias Mover = @Sendable (_ from: URL, _ to: URL) throws -> Void

    private let move: Mover
    private let current = Mutex<(id: UUID, task: Task<Void, Never>)?>(nil)
    /// Identity of the asset handed to the last `AVAssetExportSession`, for the preview/export parity check.
    public private(set) var lastExportedAssetID: ObjectIdentifier?

    public init(move: @escaping Mover = { try FileManager.default.moveItem(at: $0, to: $1) }) {
        self.move = move
    }

    /// Nonisolated so a caller-held (non-Sendable) frozen composition can be passed without sending it.
    nonisolated public func export(_ composition: AVComposition, source: URL) -> AsyncThrowingStream<ExportUpdate, Error> {
        let frozen = FrozenComposition(composition: composition)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ExportUpdate.self, throwing: Error.self)
        let id = UUID()
        let started = current.withLock { slot -> Bool in
            guard slot == nil else { return false }
            slot = (id, Task { await self.run(frozen, source: source, id: id, continuation: continuation) })
            return true
        }
        guard started else {
            continuation.finish(throwing: ExportError.alreadyExporting)
            return stream
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination {
                self.current.withLock { slot in if slot?.id == id { slot?.task.cancel() } }
            }
        }
        return stream
    }

    /// Cancels the running export and returns once it has torn down: the partial file is deleted, the
    /// stream has ended with `CancellationError`, and a new `export` can start right away.
    public func cancel() async {
        guard let task = current.withLock({ $0?.task }) else { return }
        task.cancel()
        await task.value
    }

    private func run(_ frozen: FrozenComposition, source: URL, id: UUID,
                     continuation: AsyncThrowingStream<ExportUpdate, Error>.Continuation) async {
        defer { current.withLock { slot in if slot?.id == id { slot = nil } } }
        let partial = Self.partialURL(for: source)
        do {
            try await exportPartial(frozen.composition, to: partial, continuation: continuation)
            try Task.checkCancellation()
            let final = try finalize(partial: partial, source: source)
            continuation.yield(.progress(1))
            continuation.yield(.completed(final))
            continuation.finish()
        } catch {
            try? FileManager.default.removeItem(at: partial)
            continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
        }
    }

    private func exportPartial(_ composition: AVComposition, to partial: URL,
                               continuation: AsyncThrowingStream<ExportUpdate, Error>.Continuation) async throws {
        guard await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                                                       with: composition, outputFileType: .mp4),
              let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw ExportError.incompatible }
        lastExportedAssetID = ObjectIdentifier(session.asset)

        let states = session.states(updateInterval: 0.1)
        let progress = Task {
            for await state in states {
                if case .exporting(let p) = state { continuation.yield(.progress(p.fractionCompleted)) }
            }
        }
        defer { progress.cancel() }
        try await session.export(to: partial, as: .mp4)
    }

    /// Moves the partial file to the first free `OutputNaming` candidate. Only "file exists" moves on to
    /// the next name; any other error fails at once.
    private func finalize(partial: URL, source: URL) throws -> URL {
        for n in 0...999 {
            let destination = OutputNaming.candidate(source: source, n: n)
            do {
                try move(partial, destination)
                return destination
            } catch where Self.isFileExists(error) {
                continue
            }
        }
        throw ExportError.noFreeName
    }

    static func partialURL(for source: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        return source.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).\(UUID().uuidString).sunshine-partial.mp4")
    }

    static func isFileExists(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteFileExistsError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EEXIST) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EEXIST) { return true }
        return false
    }
}

/// A frozen (immutable) `AVComposition`. Immutable compositions are only read after `copy()`, which
/// makes sharing one instance between the player, the thumbnail generator and the exporter safe.
struct FrozenComposition: @unchecked Sendable {
    let composition: AVComposition
}
