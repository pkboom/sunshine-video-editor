import AVFoundation
import Synchronization
import SunshineCore
import XCTest

/// AC 12: naming, never overwriting, cancel and finalize failures. Plus the shorter-audio-track case.
@MainActor
final class ExportServiceTests: XCTestCase {
    private static func isOutputOrPartial(_ name: String) -> Bool {
        name.contains("-edited") || name.contains("sunshine-partial")
    }

    func testSecondExportGetsNextNameAndNeverOverwrites() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.gop2bf2, in: self))
        let dir = src.url.deletingLastPathComponent()
        let sourceSHA = try Probe.sha256(src.url)
        let sourceMTime = try FileManager.default.attributesOfItem(atPath: src.url.path)[.modificationDate] as? Date
        let frozen = try await src.composition(try src.plan([(10, 20)], mode: .keep, snap: .keyframe))

        let first = try await runExport(frozen, source: src.url)
        XCTAssertEqual(first.url.lastPathComponent, "gop2_bf2-edited.mp4")
        XCTAssertEqual(first.url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        let firstSHA = try Probe.sha256(first.url)

        let second = try await runExport(frozen, source: src.url)
        XCTAssertEqual(second.url.lastPathComponent, "gop2_bf2-edited-1.mp4")
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(try Probe.sha256(first.url), firstSHA, "the first export must be untouched")
        XCTAssertEqual(try Probe.frameCount(second.url), 300)

        XCTAssertEqual(try Probe.sha256(src.url), sourceSHA)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: src.url.path)[.modificationDate] as? Date, sourceMTime)
        XCTAssertEqual(try files(in: dir, where: Self.isOutputOrPartial),
                       ["gop2_bf2-edited-1.mp4", "gop2_bf2-edited.mp4"])
        XCTAssertFalse(first.progress.isEmpty, "progress must be reported")
        XCTAssertEqual(first.progress.last, 1)
    }

    /// Cancels on the first progress update or after 50 ms, whichever comes first. The large fixture
    /// takes seconds to export, so the cancel always lands mid-export.
    func testCancelMidExportLeavesNothingBehind() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.large, in: self))
        let dir = src.url.deletingLastPathComponent()
        let frozen = try await src.composition(try src.plan([(10, 12)], mode: .remove, snap: .keyframe))

        let service = ExportService()
        let cancelled = Mutex(false)
        let timer = Task {
            try await Task.sleep(for: .milliseconds(50))
            if cancelled.withLock({ let was = $0; $0 = true; return !was }) { await service.cancel() }
        }
        defer { timer.cancel() }
        var lastProgress: Double?
        var completed: URL?
        do {
            for try await update in service.export(frozen, source: src.url) {
                switch update {
                case .progress(let p):
                    lastProgress = p
                    if cancelled.withLock({ let was = $0; $0 = true; return !was }) { await service.cancel() }
                case .completed(let url):
                    completed = url
                }
            }
            XCTFail("a cancelled export must end with an error")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error \(error)")
        }
        print("[ExportServiceTests] cancelled; last progress seen \(String(describing: lastProgress))")
        XCTAssertTrue(cancelled.withLock { $0 })
        XCTAssertNil(completed)
        XCTAssertEqual(try files(in: dir, where: Self.isOutputOrPartial), [])
    }

    /// After `cancel()` returns, the service is idle: an export started right away succeeds.
    func testExportRightAfterCancelSucceeds() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.large, in: self))
        let dir = src.url.deletingLastPathComponent()
        let long = try await src.composition(try src.plan([(10, 12)], mode: .remove, snap: .keyframe))
        let short = try await src.composition(try src.plan([(0, 2)], mode: .keep, snap: .keyframe))

        let service = ExportService()
        let first = service.export(long, source: src.url)
        await service.cancel()
        do {
            for try await _ in first {}
            XCTFail("the cancelled export must end with an error")
        } catch {
            XCTAssertTrue(error is CancellationError, "unexpected error \(error)")
        }

        let second = try await runExport(short, source: src.url, service: service)
        XCTAssertEqual(second.url.lastPathComponent, "large_1080p60-edited.mp4")
        XCTAssertEqual(try Probe.frameCount(second.url), 120)
        XCTAssertEqual(try files(in: dir, where: Self.isOutputOrPartial), ["large_1080p60-edited.mp4"])
    }

    /// The output directory turns read-only between export and finalize: the move fails at once (one
    /// attempt, no walk through the other names) and the partial file is removed. The partial lives in the
    /// same directory, so the test mover restores write access after its failed move to let cleanup run.
    func testFinalizeFailureDoesNotRetryAndRemovesPartial() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.gop2bf2, in: self))
        let dir = src.url.deletingLastPathComponent()
        let frozen = try await src.composition(try src.plan([(10, 20)], mode: .keep, snap: .keyframe))

        let attempts = Mutex<[String]>([])
        let service = ExportService(move: { from, to in
            attempts.withLock { $0.append(to.lastPathComponent) }
            let fm = FileManager.default
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
            try fm.moveItem(at: from, to: to)
        })

        do {
            _ = try await runExport(frozen, source: src.url, service: service)
            XCTFail("the move into a read-only directory must fail")
        } catch {
            let ns = error as NSError
            XCTAssertFalse(ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteFileExistsError, "\(error)")
            print("[ExportServiceTests] finalize error: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        }
        XCTAssertEqual(attempts.withLock { $0 }, ["gop2_bf2-edited.mp4"])
        XCTAssertEqual(try files(in: dir, where: Self.isOutputOrPartial), [])
    }

    /// Audio ends 1 s before video. Removing a range that spans the audio end still exports, the video
    /// frame count is exact, the audio isn't shifted at the joins, and it ends where the source audio does.
    func testShorterAudioTrackKeepsSyncAndExactVideo() async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.shortAudio, in: self))
        let audioRange = try await XCTUnwrap(src.audio).load(.timeRange)
        XCTAssertEqual(audioRange.end.seconds, 19, accuracy: 0.03)

        let plan = try src.plan([(5, 6), (18.5, 19.5)], mode: .remove, snap: .frame)
        XCTAssertEqual(plan.segments.count, 3)
        let frozen = try await src.composition(plan)
        let compositionAudio = frozen.tracks(withMediaType: .audio)[0].timeRange
        XCTAssertTimeEqual(compositionAudio.end, src.time(17.5))

        let out = try await runExport(frozen, source: src.url)
        XCTAssertEqual(try Probe.frameCount(out.url), 540)
        let ranges = try await Probe.trackRanges(out.url)
        XCTAssertTimeEqual(ranges.video.duration, CMTime(value: 18, timescale: 1))
        XCTAssertEqual(try XCTUnwrap(ranges.audio).end.seconds, 17.5, accuracy: 1024.0 / 48000.0)
        try LipSyncJoinTests.assertInSync(out.url, joins: joinTimes(plan))
    }
}
