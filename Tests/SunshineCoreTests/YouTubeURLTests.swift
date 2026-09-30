import Foundation
import Testing
@testable import SunshineCore

@Suite struct YouTubeURLTests {
    static let id = "jNQXAC9IVRw"

    @Test(arguments: [
        "https://www.youtube.com/watch?v=\(id)",
        "https://www.youtube.com/watch?v=\(id)&list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf&t=30",
        "https://youtube.com/watch?feature=share&v=\(id)",
        "https://youtu.be/\(id)?si=AbCdEfGhIjKlMnOp",
        "https://youtu.be/\(id)",
        "https://www.youtube.com/shorts/\(id)",
        "https://www.youtube.com/live/\(id)?feature=share",
        "https://www.youtube.com/embed/\(id)",
        "https://m.youtube.com/watch?v=\(id)",
        "https://music.youtube.com/watch?v=\(id)&si=x",
        "http://www.youtube.com/watch?v=\(id)",
        "www.youtube.com/watch?v=\(id)",
        "  https://www.youtube.com/watch?v=\(id)\n",
        "https://WWW.YouTube.com/watch?v=\(id)",
        "https://www.youtube.com/shorts/\(id)/",
    ])
    func accepts(_ s: String) {
        #expect(YouTubeURL.videoID(from: s) == Self.id)
    }

    @Test(arguments: [
        "https://www.youtube.com/playlist?list=PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf",
        "https://www.youtube.com/@name",
        "https://www.youtube.com/channel/UC_x5XG1OV2P6uZZ5FSM9Ttw",
        "https://www.youtube.com/c/name",
        "https://www.youtube.com/",
        "https://www.youtube.com/watch",
        "https://www.youtube.com/watch?v=jNQXAC9IVR",       // 10 chars
        "https://www.youtube.com/watch?v=jNQXAC9IVRww",     // 12 chars
        "https://www.youtube.com/watch?v=jNQXAC9IV%2Fw",
        "https://youtu.be/",
        "https://vimeo.com/\(id)",
        "https://www.youtube.com.evil.example/watch?v=\(id)",
        "https://notyoutube.com/watch?v=\(id)",
        "ftp://www.youtube.com/watch?v=\(id)",
        "-\(id)",
        "--exec=rm -rf ~ https://www.youtube.com/watch?v=\(id)",
        "",
        "   ",
        "not a url",
    ])
    func rejects(_ s: String) {
        #expect(YouTubeURL.videoID(from: s) == nil)
    }

    @Test func canonicalURL() {
        #expect(YouTubeURL.canonicalURL(id: Self.id).absoluteString == "https://www.youtube.com/watch?v=\(Self.id)")
        let id = YouTubeURL.videoID(from: "https://www.youtube.com/watch?v=\(Self.id)&list=PLx&t=30")!
        #expect(YouTubeURL.canonicalURL(id: id).absoluteString == "https://www.youtube.com/watch?v=\(Self.id)")
    }

    @Test func idsWithDashAndUnderscore() {
        #expect(YouTubeURL.videoID(from: "https://youtu.be/-_aZ09-_aZ0") == "-_aZ09-_aZ0")
    }
}
