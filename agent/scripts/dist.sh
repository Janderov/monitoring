#!/usr/bin/env bash
# Builds the install bundle in agent/dist/: Linux binaries for amd64 and arm64,
# install.sh, the systemd unit and SHA256SUMS. remote-install.sh (and later the
# Mac app) copies this bundle to a server over SSH.
#
#   agent/scripts/dist.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."
# By default the date and commit of the last change to the agent itself, so
# the version (and the app's "agent outdated" mark) changes only when the
# agent does, not with every app build.
VERSION="${1:-$(git log -1 --format=%cd-%h --date=format:%Y%m%d -- . 2>/dev/null)}"
VERSION="${VERSION:-dev}"
OUT=dist
rm -rf "$OUT"
mkdir -p "$OUT"

for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath \
    -ldflags "-s -w -X main.version=$VERSION" \
    -o "$OUT/monitor-agent-linux-$arch" ./cmd/monitor-agent
done
cp deploy/install.sh deploy/monitor-agent.service deploy/monitor-agent-flows.service "$OUT/"
echo "$VERSION" > "$OUT/VERSION"

# sha256sum on Linux, shasum on macOS; both print "<hash>  <file>".
if command -v sha256sum >/dev/null; then sum=(sha256sum); else sum=(shasum -a 256); fi
(cd "$OUT" && "${sum[@]}" monitor-agent-linux-* monitor-agent.service monitor-agent-flows.service install.sh > SHA256SUMS)

echo "built $VERSION into agent/$OUT:"
ls -l "$OUT"
