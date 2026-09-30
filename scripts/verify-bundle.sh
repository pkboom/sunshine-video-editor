#!/bin/bash
# Checks a built Sunshine.app for AC 13 portability.
#   scripts/verify-bundle.sh [path/to/Sunshine.app]   (default: dist/Sunshine.app)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/Sunshine.app}"
H="$APP/Contents/Helpers"
HELPERS=(yt-dlp deno ffmpeg)
FAILED=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }

if [[ ! -d "$APP" ]]; then
    echo "error: $APP not found. Run scripts/build-app.sh first." >&2
    exit 1
fi

# (1) helpers exist with mode 0755
for h in "${HELPERS[@]}"; do
    if [[ -f "$H/$h" && "$(stat -f '%Lp' "$H/$h")" == 755 ]]; then
        pass "(1) Helpers/$h exists, mode 0755"
    else
        fail "(1) Helpers/$h missing or mode is not 0755"
    fi
done
[[ -f "$APP/Contents/Resources/ffmpeg.LICENSE.txt" ]] && pass "(1) Resources/ffmpeg.LICENSE.txt exists" || fail "(1) Resources/ffmpeg.LICENSE.txt missing"
extra="$(ls "$H" | grep -vxE 'yt-dlp|deno|ffmpeg')"
[[ -z "$extra" ]] && pass "(1) Helpers/ holds only the three helpers" || fail "(1) unexpected files in Helpers/: $extra"

# (2) ffmpeg links only system libraries
bad_libs="$(otool -L "$H/ffmpeg" | tail -n +2 | grep -E '/opt/homebrew|/usr/local|@rpath|@loader_path|@executable_path')"
if [[ -z "$bad_libs" ]]; then
    pass "(2) otool -L ffmpeg: only /usr/lib and /System"
else
    fail "(2) ffmpeg links non-system libraries:"; echo "$bad_libs"
fi

# (3) architectures
app_archs="$(lipo -archs "$APP/Contents/MacOS/Sunshine" 2>&1)"
[[ "$app_archs" == arm64 ]] && pass "(3) MacOS/Sunshine archs: $app_archs" || fail "(3) MacOS/Sunshine archs: $app_archs (want arm64)"
for h in "${HELPERS[@]}"; do
    archs="$(lipo -archs "$H/$h" 2>&1)"
    if [[ "$archs" == arm64 ]]; then
        pass "(3) $h archs: $archs"
    elif [[ "$h" == yt-dlp && " $archs " == *" arm64 "* ]]; then
        pass "(3) $h archs: $archs (universal2 accepted)"
    else
        fail "(3) $h archs: $archs (want arm64)"
    fi
done

# (4) signature
if out="$(codesign --verify --deep --strict --verbose=2 "$APP" 2>&1)"; then
    pass "(4) codesign --verify --deep --strict"
else
    fail "(4) codesign --verify --deep --strict:"; echo "$out"
fi
for h in "${HELPERS[@]}"; do
    codesign --verify --strict "$H/$h" 2>/dev/null && pass "(4) $h signed" || fail "(4) $h signature invalid"
done

# (5) not sandboxed
ents="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"
if [[ "$ents" != *app-sandbox* ]]; then
    pass "(5) no app-sandbox entitlement"
else
    fail "(5) app-sandbox entitlement present"
fi

# (6) helpers run in a clean environment (no Homebrew on PATH)
run_clean() { env -i PATH=/usr/bin:/bin HOME="$HOME" "$@" 2>&1; }
for spec in "yt-dlp --version" "deno --version" "ffmpeg -version"; do
    set -- $spec
    if out="$(run_clean "$H/$1" "$2")"; then
        pass "(6) $1 $2 -> $(echo "$out" | head -1)"
    else
        fail "(6) $1 $2 exited non-zero:"; echo "$out" | tail -5
    fi
done

if [[ "$FAILED" == 0 ]]; then
    echo "verify-bundle: all checks passed"
else
    echo "verify-bundle: FAILED"
fi
exit "$FAILED"
