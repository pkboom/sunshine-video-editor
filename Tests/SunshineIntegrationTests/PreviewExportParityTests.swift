import AVFoundation
import SunshineCore
import XCTest

/// Principle 1 / AC 8b/8c: one frozen composition feeds the player, the thumbnail generator and the
/// exporter, and the exported video track is exactly as long as the previewed one.
@MainActor
final class PreviewExportParityTests: XCTestCase {
    func testKeepSnapped() async throws { try await checkParity(mode: .keep, snap: .keyframe) }
    func testKeepFrameExact() async throws { try await checkParity(mode: .keep, snap: .frame) }
    func testRemoveSnapped() async throws { try await checkParity(mode: .remove, snap: .keyframe) }
    func testRemoveFrameExact() async throws { try await checkParity(mode: .remove, snap: .frame) }

    private func checkParity(mode: ExportMode, snap: SnapMode) async throws {
        let src = try await LoadedSource.open(try FixtureFactory.copy(.gop2bf2, in: self))
        let plan = try src.plan([(3.3, 7.7), (20.1, 25.0), (41.2, 44.9)], mode: mode, snap: snap)
        let frozen = try await src.composition(plan)
        XCTAssertFalse(frozen is AVMutableComposition, "the shared composition must be the frozen copy")

        let item = AVPlayerItem(asset: frozen)
        let generator = AVAssetImageGenerator(asset: frozen)
        XCTAssertTrue(item.asset === frozen)
        XCTAssertTrue(generator.asset === frozen)

        let service = ExportService()
        let out = try await runExport(frozen, source: src.url, service: service)
        let exported = await service.lastExportedAssetID
        XCTAssertEqual(exported, ObjectIdentifier(frozen), "the exporter must use the preview's composition")
        XCTAssertEqual(exported, ObjectIdentifier(item.asset))
        XCTAssertEqual(exported, ObjectIdentifier(generator.asset))

        let previewVideo = frozen.tracks(withMediaType: .video)[0].timeRange
        let outputVideo = try await Probe.trackRanges(out.url).video
        XCTAssertTimeEqual(previewVideo.duration, plan.totalDuration)
        XCTAssertTimeEqual(outputVideo.duration, previewVideo.duration)
        XCTAssertTimeEqual(outputVideo.duration, plan.totalDuration)
    }
}
