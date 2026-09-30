import Foundation
import Testing
@testable import SunshineCore

// Fixtures/ytdlp_*.txt are REAL output of Homebrew yt-dlp 2026.08.19 run with the plan S3 argv
// (`--ffmpeg-location /opt/homebrew/bin/ffmpeg --js-runtimes deno:/opt/homebrew/bin/deno`),
// stdout followed by stderr. The only edit is path sanitization: the capture home dir was
// replaced with /Users/tester/Downloads and the per-job temp dir with a fixed .sunshine-dl-<uuid>.
//   *_quiet.txt                    exact S3 argv. `--print` implies quiet mode, so there are no
//                                  [Merger]/[download] lines: only SUNSHINE| and SUNSHINE_FILE|.
//   ytdlp_first_run.txt, ytdlp_second_run.txt, ytdlp_live_skip.txt, ytdlp_error_*.txt
//                                  S3 argv + `--no-quiet` (required for the [Merger] watchdog
//                                  suspension and for the live-stream skip line).
//   ytdlp_error_network.txt        + `--proxy http://127.0.0.1:9 --retries 0 --extractor-retries 0`.
//   ytdlp_live_skip.txt            a live stream (nI725iVsyoQ) skipped by `--match-filter "!is_live"`.
//   ytdlp_error_live_recording.txt an ended live stream (jfKfPfyJRdk).
// SYNTHETIC (hand-written, not captured) inputs are the inline strings in the tests marked
// "synthetic": estimate-only / NA totals, [Fixup…], paths containing `|`, and the extractor
// (outdated) error, none of which the captured runs produced.

func fixtureLines(_ name: String) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
                           "missing fixture \(name).txt")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

func events(_ lines: [String]) -> (events: [YTDLPEvent], parser: YTDLPOutputParser) {
    var parser = YTDLPOutputParser()
    let events = lines.compactMap { parser.consume(line: $0) }
    return (events, parser)
}

@Suite struct YTDLPOutputParserTests {
    static let zooPath = "/Users/tester/Downloads/Me at the zoo [jNQXAC9IVRw].mp4"

    func completions(_ e: [YTDLPEvent]) -> [String] {
        e.compactMap { if case .completed(let p) = $0 { p } else { nil } }
    }

    func errors(_ e: [YTDLPEvent]) -> [(DownloadErrorKind, String)] {
        e.compactMap { if case .error(let k, let m) = $0 { (k, m) } else { nil } }
    }

    // MARK: completion (first and second run of the same URL)

    @Test(arguments: ["ytdlp_first_run", "ytdlp_first_run_quiet"])
    func firstRunYieldsCompletedPath(_ fixture: String) throws {
        let (e, parser) = events(try fixtureLines(fixture))
        #expect(completions(e) == [Self.zooPath])
        #expect(parser.completedPath == Self.zooPath)
        #expect(errors(e).isEmpty)
    }

    @Test(arguments: ["ytdlp_second_run", "ytdlp_second_run_quiet"])
    func secondRunAlreadyDownloadedYieldsCompletedPath(_ fixture: String) throws {
        let (e, parser) = events(try fixtureLines(fixture))
        // With --no-quiet both "[download] … has already been downloaded" and SUNSHINE_FILE| name
        // the same path; the parser reports it once.
        #expect(completions(e) == [Self.zooPath])
        #expect(parser.completedPath == Self.zooPath)
        #expect(!parser.isPostProcessing)
    }

    @Test func alreadyDownloadedLineAloneCompletes() throws {
        let line = try #require(try fixtureLines("ytdlp_second_run").first { $0.hasSuffix("has already been downloaded") })
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: line) == .completed(path: Self.zooPath))
    }

    @Test func alreadyDownloadedAndMergedVariantCompletes() {
        // synthetic: wording used by older yt-dlp releases.
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: "[download] /Users/tester/Downloads/a b.mp4 has already been downloaded and merged")
                == .completed(path: "/Users/tester/Downloads/a b.mp4"))
    }

    @Test func differentPathLaterIsReported() {
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: "SUNSHINE_FILE|/a.mp4") == .completed(path: "/a.mp4"))
        #expect(parser.consume(line: "SUNSHINE_FILE|/a.mp4") == nil)
        #expect(parser.consume(line: "SUNSHINE_FILE|/b.mp4") == .completed(path: "/b.mp4"))
        #expect(parser.completedPath == "/b.mp4")
    }

    @Test func sunshineFileWithSpacesAndPipe() {
        // synthetic: titles may contain `|` (yt-dlp keeps it on macOS).
        var parser = YTDLPOutputParser()
        let path = "/Users/tester/Downloads/A | B  (live) [abcdefghijk].mp4"
        #expect(parser.consume(line: "SUNSHINE_FILE|\(path)") == .completed(path: path))
        #expect(parser.consume(line: "SUNSHINE_FILE|\(path)\n") == nil)
    }

    // MARK: progress

    @Test func realProgressWithTotalLabelsPhases() throws {
        let (e, _) = events(try fixtureLines("ytdlp_first_run"))
        let progress = e.compactMap { if case .progress(let p, let f) = $0 { (p, f) } else { nil } }
        #expect(progress.count == 20)
        #expect(progress.prefix(10).allSatisfy { $0.0 == .video })
        #expect(progress.suffix(10).allSatisfy { $0.0 == .audio })
        #expect(progress.allSatisfy { $0.1 != nil })
        // SUNSHINE|downloading|1024|433081|NA|avc1.4d400c
        #expect(progress[0].1 == 1024.0 / 433081.0)
        #expect(progress[9].1 == 1.0)
        #expect(progress[19].1 == 1.0)
    }

    @Test func progressWithTotal() {
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: "SUNSHINE|downloading|261120|433081|NA|avc1.4d400c")
                == .progress(phase: .video, fraction: 261120.0 / 433081.0))
    }

    @Test func progressEstimateOnly() {
        // synthetic: fragmented (DASH/HLS) downloads only report an estimate, sometimes as a float.
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: "SUNSHINE|downloading|500|NA|1000.0|avc1.64001f")
                == .progress(phase: .video, fraction: 0.5))
    }

    @Test func progressNAIsIndeterminate() {
        // synthetic
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: "SUNSHINE|downloading|1024|NA|NA|avc1.64001f") == .progress(phase: .video, fraction: nil))
        #expect(parser.consume(line: "SUNSHINE|downloading|NA|NA|NA|NA") == .progress(phase: .unknown, fraction: nil))
        #expect(parser.consume(line: "SUNSHINE|finished|NA|NA|NA|none") == .progress(phase: .audio, fraction: 1))
    }

    @Test func vcodecNoneIsAudio() {
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: "SUNSHINE|downloading|3072|309288|NA|none")
                == .progress(phase: .audio, fraction: 3072.0 / 309288.0))
    }

    @Test func malformedProgressIsIgnored() {
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: "SUNSHINE|downloading|1024") == nil)
    }

    // MARK: post-processing (watchdog)

    @Test func mergerLineSuspendsWatchdog() throws {
        var parser = YTDLPOutputParser()
        var sawMerging = false
        for line in try fixtureLines("ytdlp_first_run") {
            let event = parser.consume(line: line)
            if line.hasPrefix("[Merger]") {
                #expect(event == .merging)
                sawMerging = true
            }
            #expect(parser.isPostProcessing == sawMerging, "\(line)")
        }
        #expect(sawMerging)
    }

    @Test func quietRunHasNoMergerLine() throws {
        // Documents why DownloadService must pass --no-quiet.
        let (e, parser) = events(try fixtureLines("ytdlp_first_run_quiet"))
        #expect(!e.contains(.merging))
        #expect(!parser.isPostProcessing)
    }

    @Test func fixupIsMerging() {
        // synthetic
        var parser = YTDLPOutputParser()
        #expect(parser.consume(line: "[FixupM3u8] Fixing MPEG-TS in MP4 container of \"/tmp/x.mp4\"") == .merging)
        #expect(parser.isPostProcessing)
        var other = YTDLPOutputParser()
        #expect(other.consume(line: "[FixupDuplicateMoov] Fixing duplicate MOOV atoms of \"/tmp/x.mp4\"") == .merging)
    }

    // MARK: errors

    @Test func liveStreamMatchFilterSkip() throws {
        let (e, parser) = events(try fixtureLines("ytdlp_live_skip"))
        let errs = errors(e)
        #expect(errs.count == 1)
        #expect(errs.first?.0 == .liveStream)
        #expect(errs.first?.1.contains("does not pass filter (!is_live)") == true)
        #expect(parser.completedPath == nil)
    }

    @Test func endedLiveRecordingIsLiveStream() throws {
        let errs = errors(events(try fixtureLines("ytdlp_error_live_recording")).events)
        #expect(errs.map(\.0) == [.liveStream])
    }

    @Test func unavailable() throws {
        let errs = errors(events(try fixtureLines("ytdlp_error_unavailable")).events)
        #expect(errs.map(\.0) == [.unavailable])
        #expect(errs.first?.1 == "[youtube] aaaaaaaaaaa: This video is unavailable")
    }

    @Test func networkDespiteReportThisIssueBoilerplate() throws {
        let (e, _) = events(try fixtureLines("ytdlp_error_network"))
        // The WARNING line with the same text is ignored; only ERROR: counts.
        #expect(errors(e).map(\.0) == [.network])
    }

    @Test(arguments: [
        // synthetic: typical yt-dlp messages per category.
        ("ERROR: [youtube] abcdefghijk: Private video. Sign in if you've been granted access to this video", DownloadErrorKind.unavailable),
        ("ERROR: [youtube] abcdefghijk: Video unavailable. This video has been removed by the uploader", .unavailable),
        ("ERROR: [youtube] abcdefghijk: Unable to download webpage: <urlopen error [Errno 8] nodename nor servname provided, or not known>", .network),
        ("ERROR: unable to download video data: <urlopen error timed out>", .network),
        ("ERROR: [youtube] abcdefghijk: Unable to extract initial player response; please report this issue on  https://github.com/yt-dlp/yt-dlp/issues?q= , filling out the appropriate issue template. Confirm you are on the latest version using  yt-dlp -U", .outdated),
        ("ERROR: [youtube] abcdefghijk: Signature extraction failed: Some formats may be missing", .outdated),
        ("ERROR: [youtube] abcdefghijk: This live event will begin in 3 hours.", .liveStream),
        ("ERROR: [youtube] abcdefghijk: Requested format is not available. Use --list-formats for a list of available formats", .generic),
        ("ERROR: Postprocessing: Conversion failed!", .generic),
        ("ERROR: unable to open for writing: [Errno 13] Permission denied: '/private/tmp/x.mp4'", .generic),
        ("ERROR: unable to write data: [Errno 28] No space left on device", .generic),
        ("ERROR: Unable to download webpage: [Errno 1] Operation not permitted", .generic),
        ("ERROR: unable to download video data: [Errno 54] Connection reset by peer", .network),
        ("ERROR: [youtube] abcdefghijk: Unable to download API page: [Errno 65] No route to host", .network),
    ])
    func errorCategories(_ line: String, _ kind: DownloadErrorKind) {
        var parser = YTDLPOutputParser()
        guard case .error(let k, let message)? = parser.consume(line: line) else {
            Issue.record("no error for \(line)"); return
        }
        #expect(k == kind)
        #expect(message == String(line.dropFirst("ERROR: ".count)))
    }

    @Test func unrelatedLinesIgnored() throws {
        var parser = YTDLPOutputParser()
        let unrelated = try fixtureLines("ytdlp_first_run").filter {
            !$0.hasPrefix("SUNSHINE") && !$0.hasPrefix("[Merger]")
        }
        #expect(unrelated.count == 10)
        for line in unrelated + ["", "WARNING: [youtube] something", "[MoveFiles] Moving file", "Deleting original file x"] {
            #expect(parser.consume(line: line) == nil, "\(line)")
        }
        #expect(parser.completedPath == nil)
        #expect(!parser.isPostProcessing)
    }
}
