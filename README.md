# Sunshine

A small Mac app for trimming videos without re-encoding. Open a video (or paste a
YouTube link), drag across the timeline to mark ranges, then export either **only the
selected ranges** (Keep) or **the video without them** (Remove). Exports are lossless
passthrough copies, saved next to the source as `<name>-edited.mp4`.

**Requirements:** a Mac with Apple Silicon (M1 or later) running macOS 15 Sequoia or
newer. Intel Macs are not supported.

## Installing (internal)

Sunshine is for internal use and isn't notarized by Apple, so macOS needs one extra
step the first time.

1. Open `Sunshine.dmg` and drag **Sunshine** onto **Applications**, then eject the
   disk image. (From `Sunshine.zip` instead: unzip it and move `Sunshine.app` into
   `/Applications`.)
2. Open Terminal and run:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Sunshine.app
   ```

   This removes the "downloaded from the internet" flag from the app and the tools
   inside it. Without it, macOS refuses to open the app, or blocks the bundled
   YouTube downloader. If Sunshine ever shows "Helper '…' was blocked by macOS",
   run this command again.
3. Open Sunshine.
4. The first time you download a YouTube video, macOS asks whether Sunshine may
   access your **Downloads** folder. Click **Allow**. You'll get a similar prompt the
   first time you export a video that lives in your Desktop or Documents folder.

If you clicked **Don't Allow**, Sunshine shows "Sunshine can't access your … folder".
Turn the access back on in **System Settings → Privacy & Security → Files and
Folders → Sunshine**. Installing a newer build of Sunshine can make macOS ask again.

### Newer yt-dlp

YouTube changes often, and an old yt-dlp eventually stops working (Sunshine then says
"yt-dlp may be outdated"). You can use a newer one without a new Sunshine build:
download `yt-dlp_macos` from <https://github.com/yt-dlp/yt-dlp/releases>, rename it
to `yt-dlp`, and put it in `~/Library/Application Support/Sunshine/bin/`:

```sh
mkdir -p ~/Library/Application\ Support/Sunshine/bin
mv ~/Downloads/yt-dlp_macos ~/Library/Application\ Support/Sunshine/bin/yt-dlp
chmod 755 ~/Library/Application\ Support/Sunshine/bin/yt-dlp
xattr -d com.apple.quarantine ~/Library/Application\ Support/Sunshine/bin/yt-dlp
```

A file in that folder takes priority over the copy inside the app.

## Using it

- **Open File…** or drag an `.mp4`, `.mov` or `.m4v` onto the window. (macOS can't
  play `.mkv`, so Sunshine can't open those.)
- **YouTube:** paste a link to a single video and click **Download**. It saves the best
  MP4 up to 1080p to `~/Downloads` and opens it. Playlist and channel links are
  refused. Live streams aren't supported.
- **Mark ranges** by dragging across the thumbnail strip. Drag a range's edge to adjust
  it, click the strip to seek, and use ▶ / ✕ in the range list to play or delete a range.
- **Snap to keyframes** is on by default and gives the most compatible files. Turn it
  off for frame-exact cuts. Those play perfectly in QuickTime and other Apple apps,
  but some other players may flicker at the joins.
- **Preview Keep / Preview Remove** plays the result before you export it.
- **Export** saves `<name>-edited.mp4` next to the source (then `-edited-1.mp4`,
  `-edited-2.mp4`, …). It never overwrites a file. Only the first video track and the
  first audio track are kept.

## Building

You need Xcode 26 (Swift 6.3) on an Apple Silicon Mac.

```sh
scripts/fetch-helpers.sh      # downloads the pinned helpers into Helpers/ (SHA-256 checked)
scripts/build-app.sh --dmg    # builds dist/Sunshine.app and dist/Sunshine.dmg (add --zip for a zip too);
                              # the first run asks to let your terminal control Finder (window layout)
scripts/verify-bundle.sh      # checks the bundle is self-contained and signed
```

- `scripts/helpers.lock` pins each helper's version, download URL and SHA-256. To
  update one, edit its line and rerun `fetch-helpers.sh`.
- The app is ad-hoc signed and not sandboxed. There's no notarization.
- `swift test` runs the unit tests. The integration tests
  (`swift test --filter SunshineIntegrationTests`) need Homebrew `ffmpeg`/`ffprobe`
  to create and measure test videos. The app itself never uses Homebrew.
- For `swift run Sunshine` (outside a `.app`), point Sunshine at the helpers with
  `SUNSHINE_HELPERS_DIR=$PWD/Helpers swift run Sunshine`. That variable is ignored
  when running from a `.app`, and Sunshine never searches `PATH`.

## Bundled tools and licenses

`Sunshine.app/Contents/Helpers/` contains three unmodified third-party programs that
Sunshine runs as separate processes, only to download from YouTube:

| Tool | Version | Source | License |
|---|---|---|---|
| yt-dlp (`yt-dlp_macos`) | 2026.08.19 | <https://github.com/yt-dlp/yt-dlp> | Unlicense |
| Deno (JavaScript runtime used by yt-dlp) | 2.9.7 | <https://github.com/denoland/deno> | MIT |
| FFmpeg (static build, used by yt-dlp to merge video and audio) | 9.0.2 | binary: <https://ffmpeg.martin-riedl.de>, build script: <https://git.martin-riedl.de/ffmpeg/build-script>, FFmpeg source: <https://ffmpeg.org/download.html> | GPL v3 or later |

The FFmpeg build is configured with `--enable-gpl --enable-version3` and includes GPL
components such as x264 and x265, so that binary is distributed under the GNU GPL
version 3. Its license text and source links ship in
`Sunshine.app/Contents/Resources/ffmpeg.LICENSE.txt`. Sunshine's own video export
doesn't use FFmpeg. It uses Apple's AVFoundation.
