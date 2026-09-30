import AppKit
import AVFoundation
import Observation
import SunshineCore

/// A message shown in the banner under the import bar.
struct BannerMessage: Equatable {
    enum Kind: Equatable { case error, tcc, info }
    var kind: Kind
    var text: String
}

/// The editor's single source of truth. Every user action goes through `AppState.canPerform`
/// and every state change through `AppState.transition` (plan §3a).
@MainActor
@Observable
final class EditorModel {
    // MARK: State

    private(set) var state: AppState = .empty
    private(set) var banner: BannerMessage?
    /// Set after a successful export, for the "Show in Finder" banner.
    private(set) var exportedURL: URL?

    // Source
    private(set) var sourceURL: URL?
    @ObservationIgnored private(set) var sourceAsset: AVURLAsset?
    @ObservationIgnored private var videoTrack: AVAssetTrack?
    @ObservationIgnored private var audioTrack: AVAssetTrack?
    /// The loaded source as one Sendable value, for handing to the index loader.
    @ObservationIgnored private var loadedSource: LoadedSource?
    /// Edit domain D = videoTrack.timeRange.
    private(set) var domain: CMTimeRange = .zero
    private(set) var sampleIndex: SampleIndex?
    private(set) var rangeSet: RangeSet?
    private(set) var snapToKeyframes = true
    private(set) var sourceThumbnails: ThumbnailProvider?

    // Preview
    private(set) var previewMode: ExportMode?
    private(set) var previewThumbnails: ThumbnailProvider?
    /// The one frozen composition for the current plan: fed to the preview player item,
    /// the preview thumbnail generator and the exporter (Principle 1).
    @ObservationIgnored private(set) var frozen: (mode: ExportMode, version: Int, composition: AVComposition)?
    @ObservationIgnored private var planVersion = 0
    @ObservationIgnored private var sourceTimeBeforePreview: CMTime = .zero

    // Download
    var urlText = ""
    private(set) var downloadLabel = ""
    private(set) var downloadFraction: Double?
    @ObservationIgnored private let downloadService = DownloadService()
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadGeneration = 0

    // Export
    private(set) var exportProgress: Double = 0
    @ObservationIgnored private let exportService = ExportService()
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exportGeneration = 0

    // Tasks and watchers
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// Latest open request; a slower, older open that finishes later is dropped.
    @ObservationIgnored private var openGeneration = 0
    /// Bumped only when the indexed source changes (install/close) or indexing restarts, so an
    /// open that fails never orphans the running index of the current source.
    @ObservationIgnored private var indexGeneration = 0
    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?

    let playback = PlaybackController()

    // MARK: Derived

    func can(_ action: AppAction) -> Bool { state.canPerform(action) }

    var ranges: [MediaRange] { rangeSet?.ranges ?? [] }

    /// True while the preview composition is on screen, including while it is being exported.
    var isPreviewing: Bool { previewMode != nil }

    /// Remove would leave nothing when the ranges cover the whole video.
    var canRemove: Bool { !(rangeSet?.coversWholeDomain ?? true) }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    var isExporting: Bool {
        if case .exporting = state { return true }
        return false
    }

    /// The span the timeline shows: D for the source, or the composition's video duration in preview.
    var timelineSpan: CMTimeRange {
        if isPreviewing, let composition = frozen?.composition {
            return CMTimeRange(start: .zero, duration: Self.videoDuration(of: composition))
        }
        return domain
    }

    var timelineThumbnails: ThumbnailProvider? {
        isPreviewing ? previewThumbnails : sourceThumbnails
    }

    var hasSource: Bool { sourceAsset != nil }

    // MARK: Launch

    func onLaunch() {
        Task.detached(priority: .utility) { StaleFileSweeper.sweepDownloads() }
        // `Sunshine -SunshineOpen /path/to/video.mp4` opens that file. A bare path argument would be
        // taken by AppKit as a document to open, which suppresses the SwiftUI window.
        if let path = UserDefaults.standard.string(forKey: "SunshineOpen"), FileManager.default.fileExists(atPath: path) {
            open(url: URL(filePath: path))
        }
    }

    // MARK: Open

    func presentOpenPanel() {
        guard can(.openFile) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    /// Handles a drop; returns false when dropping is not allowed right now.
    func handleDrop(_ urls: [URL]) -> Bool {
        guard can(.dropFile), let url = urls.first(where: \.isFileURL) else { return false }
        open(url: url)
        return true
    }

    func open(url: URL, fromDownload: Bool = false) {
        guard !isExporting else { return }
        openGeneration += 1
        let generation = openGeneration
        Task {
            do {
                let loaded = try await Self.loadSource(url: url)
                guard generation == openGeneration, !isExporting else { return }
                install(loaded, url: url, fromDownload: fromDownload)
            } catch {
                guard generation == openGeneration else { return }
                if fromDownload { downloadEnded() }
                show(error: error, path: url)
            }
        }
    }

    private struct LoadedSource: @unchecked Sendable {
        let asset: AVURLAsset
        let videoTrack: AVAssetTrack
        let audioTrack: AVAssetTrack?
        let domain: CMTimeRange
    }

    private struct UnplayableError: LocalizedError {
        var errorDescription: String? { "macOS can't play this file. Convert it to MP4 or MOV first." }
    }

    private nonisolated static func loadSource(url: URL) async throws -> LoadedSource {
        let asset = AVURLAsset(url: url)
        do {
            let (playable, _) = try await asset.load(.isPlayable, .duration)
            guard playable, let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw UnplayableError()
            }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let domain = try await video.load(.timeRange)
            guard domain.duration > .zero else { throw UnplayableError() }
            return LoadedSource(asset: asset, videoTrack: video, audioTrack: audio, domain: domain)
        } catch let error as UnplayableError {
            throw error
        } catch {
            // Permission problems and vanished files keep their own message; anything else
            // (e.g. mkv on macOS 26) means AVFoundation can't read the container.
            if case .tccDenied = FileAccessError.classify(error, path: url) { throw error }
            if (try? url.checkResourceIsReachable()) != true { throw error }
            throw UnplayableError()
        }
    }

    private func install(_ loaded: LoadedSource, url: URL, fromDownload: Bool) {
        // The state may have moved on while the file loaded (e.g. into preview or a download);
        // only replace the source if the state machine still allows it.
        guard let next = try? state.transition(fromDownload ? .downloadFinished : .assetLoaded) else {
            if fromDownload { downloadEnded() }
            return
        }
        state = next

        sourceThumbnails?.cancel()
        clearPreviewState()
        frozen = nil
        sourceURL = url
        sourceAsset = loaded.asset
        videoTrack = loaded.videoTrack
        audioTrack = loaded.audioTrack
        loadedSource = loaded
        domain = loaded.domain
        sampleIndex = nil
        rangeSet = RangeSet(domain: loaded.domain)
        planVersion += 1
        banner = nil
        exportedURL = nil
        sourceThumbnails = ThumbnailProvider(asset: loaded.asset, span: loaded.domain)
        playback.load(asset: loaded.asset, at: loaded.domain.start)
        watch(url: url)
        Task.detached(priority: .utility) {
            StaleFileSweeper.sweepPartials(nextTo: url, activeExportPartial: nil)
        }

        startIndexing()
    }

    /// Builds the sample index for the current source. A download started during `indexing`
    /// parks the state machine in `downloading(returnTo: .indexing)`; the result is then held
    /// until the download ends (see `resumeIndexingAfterDownload`).
    private func startIndexing() {
        guard let loaded = loadedSource, let url = sourceURL else { return }
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        indexTask = Task {
            do {
                let index = try await SampleIndexLoader.load(asset: loaded.asset, videoTrack: loaded.videoTrack)
                // A newer indexing run or a closed source owns `indexTask` now.
                guard generation == indexGeneration else { return }
                indexTask = nil
                sampleIndex = index
                if state == .indexing { apply(.indexReady) }
            } catch {
                guard generation == indexGeneration else { return }
                indexTask = nil
                // While downloading, retry once the download ends instead of dropping the source.
                guard state == .indexing else { return }
                apply(.indexFailed)
                closeSource()
                show(error: error, path: url, prefix: "Couldn't read the video's frames.")
            }
        }
    }

    /// Called after a download is cancelled or fails and the state returns to where it was.
    private func resumeIndexingAfterDownload() {
        guard state == .indexing, sourceAsset != nil else { return }
        if sampleIndex != nil {
            apply(.indexReady)
        } else if indexTask == nil {
            startIndexing()
        }
    }

    private func downloadEnded() {
        downloadTask = nil
        guard isDownloading else { return }
        apply(.downloadCancelledOrFailed)
        resumeIndexingAfterDownload()
    }

    // MARK: Ranges

    /// Creates a range from a timeline drag (seconds relative to the domain start are converted here).
    @discardableResult
    func addRange(from a: Double, to b: Double) -> MediaRange.ID? {
        guard can(.editRanges), let index = sampleIndex, var set = rangeSet else { return nil }
        do {
            let id = try set.insert(from: time(a, index), to: time(b, index), index: index, mode: snapMode)
            rangeSet = set
            planChanged()
            return id
        } catch RangeSetError.emptyRange {
            return nil
        } catch {
            show(error: error)
            return nil
        }
    }

    func updateRange(id: MediaRange.ID, from a: Double, to b: Double) {
        guard can(.editRanges), let index = sampleIndex, var set = rangeSet else { return }
        do {
            try set.update(id: id, from: time(a, index), to: time(b, index), index: index, mode: snapMode)
            rangeSet = set
            planChanged()
        } catch RangeSetError.emptyRange {
            // Collapsed to nothing after clamping: leave the range as it was.
        } catch {
            show(error: error)
        }
    }

    func deleteRange(id: MediaRange.ID) {
        guard can(.editRanges), var set = rangeSet else { return }
        if playback.playingRangeID == id { playback.resetRangePlay() }
        set.delete(id: id)
        rangeSet = set
        planChanged()
    }

    func setSnapToKeyframes(_ on: Bool) {
        guard can(.toggleSnap), on != snapToKeyframes else { return }
        snapToKeyframes = on
        guard let index = sampleIndex, var set = rangeSet else { return }
        do {
            try set.resnap(index: index, mode: snapMode)
            rangeSet = set
            planChanged()
        } catch {
            show(error: error)
        }
    }

    func play(range: MediaRange) {
        guard can(.rangePlay), checkSourceReachable() else { return }
        playback.play(range: range.snapped, id: range.id)
    }

    /// Timeline click: seek with zero tolerance to seconds on the timeline's span.
    func seek(toSeconds seconds: Double) {
        guard can(.playback) else { return }
        let span = timelineSpan
        let timescale = sampleIndex?.timescale ?? span.duration.timescale
        var time = CMTime(seconds: seconds, preferredTimescale: max(timescale, 600))
        time = CMTimeClampToRange(time, range: span)
        playback.seek(to: time)
    }

    private var snapMode: SnapMode { snapToKeyframes ? .keyframe : .frame }

    /// UI seconds → CMTime in the track's timescale; `RangeSet` snaps it to a real sample time.
    private func time(_ seconds: Double, _ index: SampleIndex) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: index.timescale)
    }

    private func planChanged() {
        planVersion += 1
        exportedURL = nil
    }

    // MARK: Preview

    func enterPreview(_ mode: ExportMode) {
        guard can(.enterPreview), checkSourceReachable() else { return }
        let version = planVersion
        Task {
            guard let composition = await composition(for: mode) else { return }
            guard version == planVersion, can(.enterPreview) else { return }
            sourceTimeBeforePreview = playback.currentTime
            previewThumbnails = ThumbnailProvider(
                asset: composition,
                span: CMTimeRange(start: .zero, duration: Self.videoDuration(of: composition)))
            previewMode = mode
            playback.load(asset: composition)
            apply(.previewEntered)
        }
    }

    func exitPreview() {
        guard can(.exitPreview) else { return }
        clearPreviewState()
        playback.load(asset: sourceAsset, at: sourceTimeBeforePreview)
        apply(.previewExited)
    }

    private func clearPreviewState() {
        previewThumbnails?.cancel()
        previewThumbnails = nil
        previewMode = nil
    }

    /// Returns the frozen composition for `mode` and the current plan, building it only if the plan changed.
    private func composition(for mode: ExportMode) async -> AVComposition? {
        if let frozen, frozen.mode == mode, frozen.version == planVersion { return frozen.composition }
        guard let set = rangeSet, let videoTrack else { return nil }
        let version = planVersion
        do {
            let plan = try ExportPlan(mode: mode, ranges: set)
            let composition = try await CompositionBuilder.build(plan: plan, videoTrack: videoTrack, audioTrack: audioTrack)
            guard version == planVersion else { return nil }
            frozen = (mode, version, composition)
            return composition
        } catch {
            show(error: error, prefix: "Couldn't build the edit.")
            return nil
        }
    }

    // MARK: Export

    func export(_ mode: ExportMode) {
        guard can(.export), let source = sourceURL, checkSourceReachable() else { return }
        if isPreviewing, previewMode != mode { return }
        exportedURL = nil
        banner = nil
        Task {
            guard let composition = await composition(for: mode), can(.export) else { return }
            if isPreviewing {
                assert(playback.player.currentItem?.asset === composition, "preview/export parity")
            }
            exportProgress = 0
            apply(.exportStarted)
            let service = exportService
            exportGeneration += 1
            let generation = exportGeneration
            exportTask = Task {
                var output: URL?
                var failure: Error?
                do {
                    for try await update in service.export(composition, source: source) {
                        switch update {
                        case .progress(let fraction): exportProgress = fraction
                        case .completed(let url): output = url
                        }
                    }
                } catch is CancellationError {
                } catch {
                    failure = error
                }
                // Wait until the service has released its slot, so a new export can start at once.
                await service.cancel()
                guard generation == exportGeneration else { return }
                finishExport()
                if let failure {
                    show(error: failure, path: source, prefix: "Export failed.")
                } else if let output {
                    exportedURL = output
                }
            }
        }
    }

    /// Stops the export; the state returns to editing/preview once the export task has drained.
    func cancelExport() {
        guard can(.cancelExport) else { return }
        exportTask?.cancel()
    }

    private func finishExport() {
        exportTask = nil
        if isExporting { apply(.exportFinished) }
    }

    func showExportInFinder() {
        guard let exportedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
    }

    func dismissExportResult() { exportedURL = nil }

    // MARK: Download

    func startDownload() {
        guard can(.download) else { return }
        guard let id = YouTubeURL.videoID(from: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            banner = BannerMessage(kind: .error, text: "Paste a single video link.")
            return
        }
        banner = nil
        downloadLabel = "Starting download…"
        downloadFraction = nil
        let url = YouTubeURL.canonicalURL(id: id)
        let service = downloadService
        apply(.downloadStarted)
        downloadGeneration += 1
        let generation = downloadGeneration
        downloadTask = Task {
            var file: URL?
            var failure: Error?
            do {
                for try await update in await service.start(urlString: url.absoluteString) {
                    switch update {
                    case .progress(let label, let fraction):
                        downloadLabel = label
                        downloadFraction = fraction
                    case .completed(let completed):
                        file = completed
                    }
                }
            } catch is CancellationError {
            } catch {
                failure = error
            }
            // Wait until the service has released its job, so a new download can start at once.
            await service.cancel()
            guard generation == downloadGeneration, isDownloading else { return }
            if let file, failure == nil, !Task.isCancelled {
                downloadTask = nil
                assert(!isExporting, "download auto-open during export")
                open(url: file, fromDownload: true)
                return
            }
            downloadEnded()
            if let failure {
                show(error: failure, path: Self.downloadsDirectory, prefix: "Download failed.")
            } else if !Task.isCancelled {
                banner = BannerMessage(kind: .error, text: "The download finished without producing a file.")
            }
        }
    }

    /// Stops the download; the state returns once the download task has drained.
    func cancelDownload() {
        guard can(.cancelDownload) else { return }
        downloadTask?.cancel()
    }

    private static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Downloads")
    }

    // MARK: Source lost

    private func watch(url: URL) {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sourceLost() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        fileWatcher = source
    }

    /// Checked before preview, export and range play; goes to `empty` if the file is gone.
    private func checkSourceReachable() -> Bool {
        guard let sourceURL else { return false }
        if (try? sourceURL.checkResourceIsReachable()) == true { return true }
        sourceLost()
        return false
    }

    private func sourceLost() {
        guard sourceURL != nil else { return }
        if isDownloading {
            downloadTask?.cancel()
            downloadTask = nil
            downloadGeneration += 1
        }
        if isExporting {
            exportTask?.cancel()
            exportTask = nil
            exportGeneration += 1
        }
        apply(.sourceLost)
        closeSource()
        banner = BannerMessage(kind: .error, text: "The video file was moved or deleted.")
    }

    private func closeSource() {
        indexTask?.cancel()
        indexTask = nil
        indexGeneration += 1
        fileWatcher?.cancel()
        fileWatcher = nil
        sourceThumbnails?.cancel()
        clearPreviewState()
        playback.load(asset: nil)
        sourceURL = nil
        sourceAsset = nil
        videoTrack = nil
        audioTrack = nil
        loadedSource = nil
        domain = .zero
        sampleIndex = nil
        rangeSet = nil
        sourceThumbnails = nil
        frozen = nil
        planVersion += 1
    }

    // MARK: Banner

    func dismissBanner() { banner = nil }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    private func show(error: Error, path: URL? = nil, prefix: String? = nil) {
        if let path, case .tccDenied(let folder) = FileAccessError.classify(error, path: path) {
            banner = BannerMessage(kind: .tcc, text: "Sunshine can't access your \(folder.displayName) folder.")
            return
        }
        let detail = error.localizedDescription
        if let prefix, !(error is UnplayableError) {
            banner = BannerMessage(kind: .error, text: "\(prefix) \(detail)")
        } else {
            banner = BannerMessage(kind: .error, text: detail)
        }
    }

    // MARK: Helpers

    private func apply(_ event: AppEvent) {
        do {
            state = try state.transition(event)
        } catch {
            NSLog("Sunshine: ignored invalid transition %@ from %@", "\(event)", "\(state)")
        }
    }

    static func videoDuration(of asset: AVAsset) -> CMTime {
        (asset as? AVComposition)?.tracks(withMediaType: .video).first?.timeRange.duration ?? .zero
    }
}

extension ProtectedFolder {
    var displayName: String {
        switch self {
        case .downloads: "Downloads"
        case .desktop: "Desktop"
        case .documents: "Documents"
        }
    }
}
