/// The app state machine (plan §3a). Controls whose action `canPerform` rejects are disabled.
public enum AppState: Equatable, Sendable {
    case empty
    case indexing
    case editing
    case previewing
    case downloading(returnTo: ReturnState)
    case exporting(returnTo: ReturnState)
}

/// The state a download or export returns to when it ends without opening a new source.
public enum ReturnState: Equatable, Sendable {
    case empty, indexing, editing, previewing

    public var state: AppState {
        switch self {
        case .empty: .empty
        case .indexing: .indexing
        case .editing: .editing
        case .previewing: .previewing
        }
    }
}

public enum AppAction: Sendable, CaseIterable {
    case openFile, dropFile, download, cancelDownload, playback, editRanges, toggleSnap, rangePlay,
         enterPreview, exitPreview, export, cancelExport, autoOpen
}

public enum AppEvent: Sendable, CaseIterable {
    case assetLoaded, indexReady, indexFailed, previewEntered, previewExited, downloadStarted,
         downloadFinished, downloadCancelledOrFailed, exportStarted, exportFinished, sourceLost, closed
}

public enum AppStateError: Error, Equatable, Sendable {
    case invalidTransition(from: AppState, event: AppEvent)
}

extension AppState {
    public func canPerform(_ a: AppAction) -> Bool {
        switch self {
        case .empty:
            return [.openFile, .dropFile, .download].contains(a)
        case .indexing:
            return [.playback, .openFile, .dropFile, .download].contains(a)
        case .editing:
            return [.openFile, .dropFile, .download, .playback, .editRanges, .toggleSnap, .rangePlay,
                    .enterPreview, .export].contains(a)
        case .previewing:
            return [.playback, .exitPreview, .export].contains(a)
        case .downloading(let returnTo):
            switch a {
            case .cancelDownload, .autoOpen: return true
            // The current video, if any, may still play while downloading.
            case .playback: return returnTo != .empty
            default: return false
            }
        case .exporting:
            return [.playback, .cancelExport].contains(a)
        }
    }

    public func transition(_ e: AppEvent) throws -> AppState {
        // Cross-cutting: losing the source or closing it empties the editor from any state.
        // Any in-flight job is cancelled by the caller first.
        if e == .sourceLost || e == .closed { return .empty }

        switch (self, e) {
        case (.empty, .assetLoaded), (.indexing, .assetLoaded), (.editing, .assetLoaded):
            return .indexing
        case (.empty, .downloadStarted):
            return .downloading(returnTo: .empty)
        case (.indexing, .downloadStarted):
            return .downloading(returnTo: .indexing)
        case (.editing, .downloadStarted):
            return .downloading(returnTo: .editing)
        case (.indexing, .indexReady):
            return .editing
        case (.indexing, .indexFailed):
            return .empty
        case (.editing, .previewEntered):
            return .previewing
        case (.previewing, .previewExited):
            return .editing
        case (.editing, .exportStarted):
            return .exporting(returnTo: .editing)
        case (.previewing, .exportStarted):
            return .exporting(returnTo: .previewing)
        case (.downloading, .downloadFinished):
            // Auto-open of the downloaded file.
            return .indexing
        case (.downloading(let returnTo), .downloadCancelledOrFailed):
            return returnTo.state
        case (.exporting(let returnTo), .exportFinished):
            return returnTo.state
        default:
            throw AppStateError.invalidTransition(from: self, event: e)
        }
    }
}
