import Testing
@testable import SunshineCore

@Suite struct AppStateTests {
    static let allStates: [AppState] = [
        .empty, .indexing, .editing, .previewing,
        .downloading(returnTo: .empty), .downloading(returnTo: .indexing), .downloading(returnTo: .editing),
        .exporting(returnTo: .editing), .exporting(returnTo: .previewing),
    ]

    /// Plan §3a "Allowed actions".
    static func allowed(_ s: AppState) -> Set<String> {
        switch s {
        case .empty: ["openFile", "dropFile", "download"]
        case .indexing: ["playback", "openFile", "dropFile", "download"]
        case .editing: ["openFile", "dropFile", "download", "playback", "editRanges", "toggleSnap", "rangePlay",
                        "enterPreview", "export"]
        case .previewing: ["playback", "exitPreview", "export"]
        case .downloading(.empty): ["cancelDownload", "autoOpen"]
        case .downloading: ["cancelDownload", "autoOpen", "playback"]
        case .exporting: ["playback", "cancelExport"]
        }
    }

    /// Plan §3a "Exits to" (plus the cross-cutting source-lost/close rule).
    static func expectedTransition(_ s: AppState, _ e: AppEvent) -> AppState? {
        if case .downloading = s, e == .sourceLost { return .downloading(returnTo: .empty) }
        if e == .sourceLost || e == .closed { return .empty }
        switch (s, e) {
        case (.empty, .assetLoaded), (.indexing, .assetLoaded), (.editing, .assetLoaded): return .indexing
        case (.empty, .downloadStarted): return .downloading(returnTo: .empty)
        case (.indexing, .downloadStarted): return .downloading(returnTo: .indexing)
        case (.editing, .downloadStarted): return .downloading(returnTo: .editing)
        case (.indexing, .indexReady): return .editing
        case (.indexing, .indexFailed): return .empty
        case (.editing, .previewEntered): return .previewing
        case (.previewing, .previewExited): return .editing
        case (.editing, .exportStarted): return .exporting(returnTo: .editing)
        case (.previewing, .exportStarted): return .exporting(returnTo: .previewing)
        case (.downloading, .downloadFinished): return .indexing
        case (.downloading(.empty), .downloadCancelledOrFailed): return .empty
        case (.downloading(.indexing), .downloadCancelledOrFailed): return .indexing
        case (.downloading(.editing), .downloadCancelledOrFailed): return .editing
        case (.exporting(.editing), .exportFinished): return .editing
        case (.exporting(.previewing), .exportFinished): return .previewing
        default: return nil
        }
    }

    @Test(arguments: allStates)
    func everyActionMatchesTable(_ state: AppState) {
        let expected = Self.allowed(state)
        for action in AppAction.allCases {
            #expect(state.canPerform(action) == expected.contains("\(action)"), "\(state) \(action)")
        }
    }

    @Test(arguments: [AppState.exporting(returnTo: .editing), .exporting(returnTo: .previewing)])
    func exportingBlocksEverythingButPlaybackAndCancel(_ state: AppState) {
        for action in [AppAction.openFile, .dropFile, .download, .autoOpen, .editRanges, .toggleSnap, .export,
                       .enterPreview, .exitPreview, .rangePlay, .cancelDownload] {
            #expect(!state.canPerform(action), "\(action)")
        }
        #expect(state.canPerform(.playback))
        #expect(state.canPerform(.cancelExport))
    }

    @Test(arguments: allStates)
    func everyTransitionMatchesTable(_ state: AppState) throws {
        for event in AppEvent.allCases {
            if let next = Self.expectedTransition(state, event) {
                #expect(try state.transition(event) == next, "\(state) \(event)")
            } else {
                #expect(throws: AppStateError.invalidTransition(from: state, event: event)) {
                    try state.transition(event)
                }
            }
        }
    }

    @Test(arguments: [AppState.empty, .indexing, .editing, .previewing,
                      .exporting(returnTo: .editing), .exporting(returnTo: .previewing)])
    func sourceLostOutsideADownloadGoesEmpty(_ state: AppState) throws {
        #expect(try state.transition(.sourceLost) == .empty)
    }

    @Test(arguments: [AppState.downloading(returnTo: .empty), .downloading(returnTo: .indexing),
                      .downloading(returnTo: .editing)])
    func sourceLostDuringDownloadKeepsDownloading(_ state: AppState) throws {
        let next = try state.transition(.sourceLost)
        #expect(next == .downloading(returnTo: .empty))
        #expect(try next.transition(.downloadFinished) == .indexing)
        #expect(try next.transition(.downloadCancelledOrFailed) == .empty)
    }

    @Test func invalidTransitionsThrow() {
        #expect(throws: AppStateError.self) { try AppState.empty.transition(.indexReady) }
        #expect(throws: AppStateError.self) { try AppState.previewing.transition(.assetLoaded) }
        #expect(throws: AppStateError.self) { try AppState.previewing.transition(.downloadStarted) }
        #expect(throws: AppStateError.self) { try AppState.exporting(returnTo: .editing).transition(.downloadStarted) }
        #expect(throws: AppStateError.self) { try AppState.exporting(returnTo: .editing).transition(.exportStarted) }
        #expect(throws: AppStateError.self) { try AppState.downloading(returnTo: .editing).transition(.downloadStarted) }
    }

    @Test func downloadRoundTripKeepsCurrentSource() throws {
        let downloading = try AppState.editing.transition(.downloadStarted)
        #expect(downloading.canPerform(.playback))
        #expect(!downloading.canPerform(.editRanges))
        #expect(try downloading.transition(.downloadCancelledOrFailed) == .editing)
        #expect(try downloading.transition(.downloadFinished) == .indexing)
    }

    @Test func exportFromPreviewReturnsToPreview() throws {
        let exporting = try AppState.previewing.transition(.exportStarted)
        #expect(exporting == .exporting(returnTo: .previewing))
        #expect(try exporting.transition(.exportFinished) == .previewing)
    }
}
