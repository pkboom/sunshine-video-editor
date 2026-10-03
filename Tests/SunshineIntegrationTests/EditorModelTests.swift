import SunshineCore
import XCTest
@testable import Sunshine

@MainActor
final class EditorModelTests: XCTestCase {
    func testLosingTheSourceKeepsTheDownloadRunning() async throws {
        let source = try FixtureFactory.copy(.flashbeep, in: self)
        let model = try makeModel()
        model.open(url: source)
        try await waitUntil { model.state == .editing }

        startHangingDownload(model)
        XCTAssertEqual(model.state, .downloading(returnTo: .editing))
        try FileManager.default.removeItem(at: source)
        try await waitUntil { !model.hasSource }

        XCTAssertEqual(model.state, .downloading(returnTo: .empty))
        model.cancelDownload()
        try await waitUntil { model.state == .empty }
    }

    func testOpenDroppedByABusyEditorShowsABanner() async throws {
        let source = try FixtureFactory.copy(.flashbeep, in: self)
        let model = try makeModel()
        model.open(url: source)
        startHangingDownload(model)
        try await waitUntil { model.banner != nil }

        XCTAssertEqual(model.banner?.kind, .info)
        XCTAssertTrue(model.banner?.text.contains(source.lastPathComponent) == true, model.banner?.text ?? "")
        XCTAssertFalse(model.hasSource)
        model.cancelDownload()
        try await waitUntil { model.state == .empty }
    }

    private func makeModel() throws -> EditorModel {
        let dir = try FixtureFactory.makeTempDir(in: self)
        let helper = dir.appendingPathComponent("hang")
        try "#!/bin/sh\nexec sleep 30\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return EditorModel(downloadService: DownloadService(downloadsDirectory: dir, locate: { _ in helper }))
    }

    private func startHangingDownload(_ model: EditorModel) {
        model.urlText = "https://youtu.be/dQw4w9WgXcQ"
        model.startDownload()
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for condition", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
