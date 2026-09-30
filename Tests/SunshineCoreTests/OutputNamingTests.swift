import Foundation
import Testing
@testable import SunshineCore

@Suite struct OutputNamingTests {
    let dir = URL(fileURLWithPath: "/Users/tester/Movies", isDirectory: true)

    func name(_ source: String, existing: Set<String> = []) -> String {
        OutputNaming.firstFree(source: dir.appendingPathComponent(source)) { existing.contains($0.lastPathComponent) }
            .lastPathComponent
    }

    @Test func noneExisting() {
        #expect(name("clip.mp4") == "clip-edited.mp4")
    }

    @Test func existingGivesOne() {
        #expect(name("clip.mp4", existing: ["clip-edited.mp4"]) == "clip-edited-1.mp4")
    }

    @Test func threeExistingGivesThree() {
        #expect(name("clip.mp4", existing: ["clip-edited.mp4", "clip-edited-1.mp4", "clip-edited-2.mp4"]) == "clip-edited-3.mp4")
    }

    @Test func movSourceGivesMP4() {
        #expect(name("clip.mov") == "clip-edited.mp4")
        #expect(name("clip.m4v", existing: ["clip-edited.mp4"]) == "clip-edited-1.mp4")
    }

    @Test func unicodeAndSpaceStems() {
        #expect(name("Me at the zoo [jNQXAC9IVRw].mp4") == "Me at the zoo [jNQXAC9IVRw]-edited.mp4")
        #expect(name("비디오 클립 🎬.mov") == "비디오 클립 🎬-edited.mp4")
    }

    @Test func dottedStem() {
        #expect(name("my.clip.v2.mp4") == "my.clip.v2-edited.mp4")
    }

    @Test func candidateIsNextToSource() {
        let source = dir.appendingPathComponent("clip.mov")
        #expect(OutputNaming.candidate(source: source, n: 0) == dir.appendingPathComponent("clip-edited.mp4"))
        #expect(OutputNaming.candidate(source: source, n: 7) == dir.appendingPathComponent("clip-edited-7.mp4"))
    }
}
