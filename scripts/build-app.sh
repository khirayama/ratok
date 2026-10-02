#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
ratok_bin=$(swift build -c release --show-bin-path)
mkdir -p dist/Ratok.app/Contents/MacOS dist/Ratok.app/Contents/Frameworks dist/Ratok.app/Contents/Resources
cp .build/artifacts/sparkle/Sparkle/LICENSE dist/Ratok.app/Contents/Resources/Sparkle-LICENSE
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework dist/Ratok.app/Contents/Frameworks/Sparkle.framework
cp "$ratok_bin/Ratok" dist/Ratok.app/Contents/MacOS/Ratok
cat > dist/Ratok.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ratok</string>
<key>CFBundleIdentifier</key><string>dev.ratok.mac</string>
<key>CFBundleName</key><string>Ratok</string>
<key>CFBundleDisplayName</key><string>Ratok</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - <<'PYCONFIG'
import base64
import os
import plistlib
from urllib.parse import urlparse

path = "dist/Ratok.app/Contents/Info.plist"
with open(path, "rb") as file:
    info = plistlib.load(file)
info["CFBundleShortVersionString"] = os.environ.get("RATOK_VERSION", "0.1.0")
info["CFBundleVersion"] = os.environ.get("RATOK_BUILD_NUMBER", "1")
feed = os.environ.get("RATOK_UPDATE_FEED_URL", "")
key = os.environ.get("RATOK_UPDATE_PUBLIC_KEY", "")
if feed or key:
    parsed = urlparse(feed)
    if parsed.scheme != "https" or not parsed.hostname:
        raise SystemExit("RATOK_UPDATE_FEED_URL must be an HTTPS URL")
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise SystemExit("RATOK_UPDATE_PUBLIC_KEY must be a base64 encoded Ed25519 public key")
    info.update(SUFeedURL=feed, SUPublicEDKey=key, SUEnableAutomaticChecks=True,
                SUAutomaticallyUpdate=False, SUVerifyUpdateBeforeExtraction=True)
with open(path, "wb") as file:
    plistlib.dump(info, file)
PYCONFIG
if [ -n "${APPLE_SIGNING_IDENTITY:-}" ]; then
    codesign --force --deep --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" dist/Ratok.app
else
    rtk proxy codesign --force --deep --sign - dist/Ratok.app
fi
printf '\nBuilt: dist/Ratok.app\n'
