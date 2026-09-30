#!/bin/bash
# Downloads the pinned arm64 helpers from scripts/helpers.lock into Helpers/.
# Every download is SHA-256 verified; a mismatch aborts with a non-zero exit.
# Idempotent: cached downloads and already-installed helpers are reused.
#   scripts/fetch-helpers.sh           fetch/install as needed
#   scripts/fetch-helpers.sh --check   only verify Helpers/ against the lock (no network)
set -euo pipefail

CHECK=0
case "${1:-}" in
    "") ;;
    --check) CHECK=1 ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/helpers.lock"
OUT="$ROOT/Helpers"
CACHE="$OUT/.cache"

mkdir -p "$OUT" "$CACHE"

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# fetch <url> <sha256> -> prints path of verified cached file
fetch() {
    local url="$1" sha="$2"
    local file="$CACHE/$sha-$(basename "$url")"
    if [[ -f "$file" && "$(sha_of "$file")" == "$sha" ]]; then
        echo "$file"
        return
    fi
    echo "  downloading $url" >&2
    curl -fL --retry 3 --silent --show-error -o "$file.tmp" "$url"
    local got
    got="$(sha_of "$file.tmp")"
    if [[ "$got" != "$sha" ]]; then
        rm -f "$file.tmp"
        echo "error: SHA-256 mismatch for $url" >&2
        echo "  expected $sha" >&2
        echo "  got      $got" >&2
        exit 1
    fi
    mv "$file.tmp" "$file"
    echo "$file"
}

# install <src> <dest-name>: copy as an executable, drop extended attributes
install_bin() {
    local src="$1" dest="$OUT/$2"
    cp -f "$src" "$dest.tmp"
    chmod 755 "$dest.tmp"
    xattr -c "$dest.tmp"
    mv -f "$dest.tmp" "$dest"
}

# unzip_member <zip> <member> <dest-name>
unzip_member() {
    local zip="$1" member="$2" name="$3"
    local tmp
    tmp="$(mktemp -d "$CACHE/unzip.XXXXXX")"
    unzip -q -o "$zip" "$member" -d "$tmp"
    install_bin "$tmp/$member" "$name"
    rm -rf "$tmp"
}

# The stamp records "<lock sha> <sha of the installed binary>". For zips the lock sha is
# the archive's, so the installed binary is re-hashed against the sha recorded when it
# was extracted from the verified archive.
installed_ok() {
    local name="$1" sha="$2" stamp="$CACHE/$1.stamp"
    [[ -f "$OUT/$name" && -f "$stamp" ]] || return 1
    local lock_sha bin_sha
    read -r lock_sha bin_sha < "$stamp" || return 1
    [[ "$lock_sha" == "$sha" && -n "$bin_sha" && "$(sha_of "$OUT/$name")" == "$bin_sha" ]]
}

write_stamp() { echo "$2 $(sha_of "$OUT/$1")" > "$CACHE/$1.stamp"; }

# ensure <name> <url> <sha> <zip member or empty>
ensure() {
    local name="$1" url="$2" sha="$3" member="$4"
    if installed_ok "$name" "$sha"; then
        return
    fi
    if [[ "$CHECK" == 1 ]]; then
        echo "error: Helpers/$name is missing or doesn't match helpers.lock. Run scripts/fetch-helpers.sh." >&2
        exit 1
    fi
    local file
    file="$(fetch "$url" "$sha")"
    if [[ ! -f "$file" ]]; then
        echo "error: download of $url produced no file" >&2
        exit 1
    fi
    if [[ -z "$member" ]]; then
        # A raw binary: the installed file must hash exactly to the lock.
        install_bin "$file" "$name"
        if [[ "$(sha_of "$OUT/$name")" != "$sha" ]]; then
            echo "error: installed Helpers/$name doesn't match helpers.lock" >&2
            exit 1
        fi
    else
        unzip_member "$file" "$member" "$name"
    fi
    write_stamp "$name" "$sha"
}

FFMPEG_VERSION="" FFMPEG_URL="" GPL_FILE=""

while IFS='|' read -r name version url sha; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    echo "$name $version"
    case "$name" in
        yt-dlp) ensure yt-dlp "$url" "$sha" "" ;;
        deno)   ensure deno "$url" "$sha" deno ;;
        ffmpeg)
            FFMPEG_VERSION="$version" FFMPEG_URL="$url"
            ensure ffmpeg "$url" "$sha" ffmpeg
            ;;
        gpl-3.0)
            if [[ "$CHECK" == 0 ]]; then
                GPL_FILE="$(fetch "$url" "$sha")"
                [[ -f "$GPL_FILE" ]] || { echo "error: download of $url produced no file" >&2; exit 1; }
            fi
            ;;
        *)
            echo "error: unknown helper '$name' in $LOCK" >&2
            exit 1
            ;;
    esac
done < "$LOCK"

if [[ "$CHECK" == 1 ]]; then
    if [[ ! -s "$OUT/ffmpeg.LICENSE.txt" ]]; then
        echo "error: Helpers/ffmpeg.LICENSE.txt is missing. Run scripts/fetch-helpers.sh." >&2
        exit 1
    fi
    echo "Helpers/ matches helpers.lock"
    exit 0
fi

if [[ -z "$FFMPEG_URL" || -z "$GPL_FILE" ]]; then
    echo "error: helpers.lock must pin both ffmpeg and gpl-3.0" >&2
    exit 1
fi

{
    cat <<EOF
FFmpeg ${FFMPEG_VERSION} (static macOS arm64 build by Martin Riedl)

This copy of ffmpeg is an unmodified, separately distributed executable.
Sunshine only runs it as a subprocess of yt-dlp to merge downloaded
video and audio streams.

FFmpeg is licensed under the GNU General Public License, version 3 or later,
for this build (configured with --enable-gpl --enable-version3; it includes
GPL components such as x264 and x265).

Binary:        ${FFMPEG_URL}
Build script:  https://git.martin-riedl.de/ffmpeg/build-script
FFmpeg source: https://ffmpeg.org/download.html  (release ${FFMPEG_VERSION})
FFmpeg legal:  https://ffmpeg.org/legal.html

The full text of the GNU GPL version 3 follows.

EOF
    cat "$GPL_FILE"
} > "$OUT/ffmpeg.LICENSE.txt"
xattr -c "$OUT/ffmpeg.LICENSE.txt"

echo "Helpers ready in $OUT:"
ls -l "$OUT" | grep -v '^total'
