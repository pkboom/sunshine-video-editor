import Foundation
import Testing
@testable import SunshineCore

@Suite struct StaleFileSweeperTests {
    let uuid = "0F3E5C3A-4B7E-4D2A-9C1E-6A1B2C3D4E5F"

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func age(_ url: URL, hours: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hours * 3600)],
                                              ofItemAtPath: url.path)
    }

    @Test func sweepDownloadsRemovesOnlyOwnTempDirectories() throws {
        let t = try TempDir()
        let ours = try t.dir(".sunshine-dl-\(uuid)")
        try t.file(".sunshine-dl-\(uuid)/Video.f137.mp4.part")
        let notUUID = try t.dir(".sunshine-dl-mine")
        let fileNotDir = try t.file(".sunshine-dl-\(UUID().uuidString)")
        let video = try t.file("Video [abc].mp4")
        let other = try t.dir("sunshine-dl-\(uuid)")

        StaleFileSweeper.sweepDownloads(in: t.url)

        #expect(!exists(ours))
        #expect(exists(notUUID))
        #expect(exists(fileNotDir))
        #expect(exists(video))
        #expect(exists(other))
    }

    @Test func sweepPartialsRemovesOldPartialsOfThisSource() throws {
        let t = try TempDir()
        let source = try t.file("clip.mp4")
        let old = try t.file(".clip.\(uuid).sunshine-partial.mp4")
        try age(old, hours: 2)

        StaleFileSweeper.sweepPartials(nextTo: source, activeExportPartial: nil)

        #expect(!exists(old))
        #expect(exists(source))
    }

    @Test func sweepPartialsKeepsFreshActiveAndForeignFiles() throws {
        let t = try TempDir()
        let source = try t.file("clip.mov")
        let fresh = try t.file(".clip.\(UUID().uuidString).sunshine-partial.mp4")
        try age(fresh, hours: 0.5)
        let active = try t.file(".clip.\(UUID().uuidString).sunshine-partial.mp4")
        try age(active, hours: 3)
        let otherSource = try t.file(".other.\(UUID().uuidString).sunshine-partial.mp4")
        try age(otherSource, hours: 3)
        let otherDotted = try t.file(".clip.v2.\(UUID().uuidString).sunshine-partial.mp4")
        try age(otherDotted, hours: 3)
        let notUUID = try t.file(".clip.backup.sunshine-partial.mp4")
        try age(notUUID, hours: 3)
        let edited = try t.file("clip-edited.mp4")
        try age(edited, hours: 3)

        StaleFileSweeper.sweepPartials(nextTo: source, activeExportPartial: active)

        for url in [fresh, active, otherSource, otherDotted, notUUID, edited, source] {
            #expect(exists(url), "\(url.lastPathComponent) must survive")
        }
    }

    @Test func dottedAndUnicodeStems() throws {
        let t = try TempDir()
        let source = try t.file("my.clip v2 ☀️.mp4")
        let old = try t.file(".my.clip v2 ☀️.\(uuid).sunshine-partial.mp4")
        try age(old, hours: 2)
        StaleFileSweeper.sweepPartials(nextTo: source, activeExportPartial: nil)
        #expect(!exists(old))
    }

    @Test func partialNameMatchesExportService() throws {
        let source = URL(fileURLWithPath: "/tmp/my.clip.mov")
        let partial = ExportService.partialURL(for: source)
        let name = partial.lastPathComponent
        #expect(name.hasPrefix(".my.clip."))
        #expect(name.hasSuffix(StaleFileSweeper.partialSuffix))
        let middle = name.dropFirst(".my.clip.".count).dropLast(StaleFileSweeper.partialSuffix.count)
        #expect(UUID(uuidString: String(middle)) != nil)
    }
}
