#!/bin/bash
# Downloads a pinned Mole release into Vendor/mole, verifying checksums.
# Scripts come from the tagged source tarball; the Go helpers come from the
# release's prebuilt binaries, merged into universal (arm64 + x86_64) files.
set -euo pipefail

MOLE_VERSION="1.49.2"
TARBALL_SHA256="ffa39b625416ac150587bcc93dfccac83c6eece6922b87ccc8d3000875ff3885"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Vendor/mole"
TAG="V${MOLE_VERSION}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching Mole ${MOLE_VERSION}..."
curl -fsSL -o "$WORK/src.tar.gz" "https://github.com/tw93/Mole/archive/refs/tags/${TAG}.tar.gz"
echo "${TARBALL_SHA256}  $WORK/src.tar.gz" | shasum -a 256 -c -

tar -xzf "$WORK/src.tar.gz" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'Mole-*' | head -1)"
[[ -n "$SRC" ]] || { echo "error: unexpected tarball layout" >&2; exit 1; }

RELEASE_URL="https://github.com/tw93/Mole/releases/download/${TAG}"
curl -fsSL -o "$WORK/SHA256SUMS" "$RELEASE_URL/SHA256SUMS"
for tool in analyze status; do
    for arch in arm64 amd64; do
        asset="${tool}-darwin-${arch}"
        curl -fsSL -o "$WORK/$asset" "$RELEASE_URL/$asset"
        expected="$(awk -v a="$asset" '$2 == a || $2 == "*"a {print $1}' "$WORK/SHA256SUMS")"
        [[ -n "$expected" ]] || { echo "error: no checksum for $asset" >&2; exit 1; }
        echo "${expected}  $WORK/$asset" | shasum -a 256 -c -
    done
done

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$SRC/mole" "$DEST/mole"
cp -R "$SRC/bin" "$SRC/lib" "$DEST/"
cp "$SRC/LICENSE" "$DEST/LICENSE"
rm -f "$DEST"/bin/*-go
for tool in analyze status; do
    lipo -create "$WORK/${tool}-darwin-arm64" "$WORK/${tool}-darwin-amd64" -output "$DEST/bin/${tool}-go"
done
chmod +x "$DEST/mole" "$DEST"/bin/*
echo "$MOLE_VERSION" > "$DEST/VERSION"
echo "Mole ${MOLE_VERSION} vendored at Vendor/mole"
