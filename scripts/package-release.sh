#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

: "${GITHUB_REF_NAME:?Run this script from a version tag, for example v0.2.0}"
: "${RATOK_UPDATE_PUBLIC_KEY:?Set the Sparkle public key as a GitHub Actions variable}"
: "${SPARKLE_PRIVATE_KEY:?Set the exported Sparkle private key as a GitHub Actions secret}"

version=${GITHUB_REF_NAME#v}
python3 - "$version" <<'PYVERSION'
import re
import sys
if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", sys.argv[1]):
    raise SystemExit(f"Tag must be vMAJOR.MINOR.PATCH (got {sys.argv[1]!r})")
PYVERSION
build_number=$version
feed_url="https://github.com/khirayama/ratok/releases/latest/download/appcast.xml"

RATOK_VERSION="$version" \
RATOK_BUILD_NUMBER="$build_number" \
RATOK_UPDATE_FEED_URL="$feed_url" \
RATOK_UPDATE_PUBLIC_KEY="$RATOK_UPDATE_PUBLIC_KEY" \
sh scripts/build-app.sh

codesign --verify --deep --strict --verbose=2 dist/Ratok.app

mkdir -p dist/release
archive="Ratok-$version.zip"
ditto -c -k --sequesterRsrc --keepParent dist/Ratok.app "dist/release/$archive"

sparkle_bin=".build/artifacts/sparkle/Sparkle/bin"
printf '%s' "$SPARKLE_PRIVATE_KEY" | \
    "$sparkle_bin/generate_appcast" --ed-key-file - \
    --download-url-prefix "https://github.com/khirayama/ratok/releases/download/$GITHUB_REF_NAME/" \
    -o dist/release/appcast.xml dist/release

test -s dist/release/appcast.xml
echo "Release assets prepared in dist/release"
