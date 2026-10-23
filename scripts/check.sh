#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

swift --version
resolved_checksum=$(shasum -a 256 Package.resolved)
for script in scripts/*.sh; do
    sh -n "$script"
done
swift test --force-resolved-versions -Xswiftc -warnings-as-errors
if [ "$resolved_checksum" != "$(shasum -a 256 Package.resolved)" ]; then
    echo "Package.resolved changed during verification" >&2
    exit 1
fi
