#!/bin/bash
# Downloads a pinned Mole release into Vendor/mole, verifying checksums.
# Scripts come from the tagged commit's source; the Go helpers come from the
# release's prebuilt binaries, merged into universal (arm64 + x86_64) files.
#
# The source is verified by a hash of its extracted files, not of the tarball,
# because GitHub can regenerate archive bytes without changing their contents.
set -euo pipefail

MOLE_VERSION="1.49.2"
MOLE_COMMIT="7d8d6faba687a8ece3f83d3a20de091965fff677" # tag V1.49.2
SOURCE_TREE_SHA256="f081ca3ecb01ba7634f2059d571b52ed8b69f0e38def208cc7382ae34ae97331"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Vendor/mole"
TAG="V${MOLE_VERSION}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching Mole ${MOLE_VERSION}..."
curl -fsSL -o "$WORK/src.tar.gz" "https://github.com/tw93/Mole/archive/${MOLE_COMMIT}.tar.gz"
tar -xzf "$WORK/src.tar.gz" -C "$WORK"
SRC="$(find "$WORK" -maxdepth 1 -type d -name 'Mole-*' | head -1)"
[[ -n "$SRC" ]] || { echo "error: unexpected tarball layout" >&2; exit 1; }
rm -f "$SRC"/bin/*-go

tree_hash="$(cd "$SRC" && find mole bin lib LICENSE -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
if [[ "$tree_hash" != "$SOURCE_TREE_SHA256" ]]; then
    echo "error: Mole source hash mismatch (got $tree_hash)" >&2
    exit 1
fi

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
for tool in analyze status; do
    lipo -create "$WORK/${tool}-darwin-arm64" "$WORK/${tool}-darwin-amd64" -output "$DEST/bin/${tool}-go"
done
chmod +x "$DEST/mole" "$DEST"/bin/*
echo "$MOLE_VERSION" > "$DEST/VERSION"
echo "Mole ${MOLE_VERSION} vendored at Vendor/mole"
