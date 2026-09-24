#!/bin/bash
# Xcode build phase: copies the vendored Mole into the app's Resources and signs
# its Mach-O helpers so the app passes notarization.
set -euo pipefail

SRC="${SRCROOT}/Vendor/mole"
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/mole"

if [[ ! -x "$SRC/mole" ]]; then
    echo "error: Mole is not vendored. Run scripts/fetch-mole.sh first." >&2
    exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SRC/mole" "$SRC/bin" "$SRC/lib" "$SRC/LICENSE" "$SRC/VERSION" "$DEST/"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[[ -n "$IDENTITY" ]] || IDENTITY="-"
SIGN_ARGS=(--force --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--timestamp)
fi

while IFS= read -r -d '' file; do
    if file "$file" | grep -q "Mach-O"; then
        codesign "${SIGN_ARGS[@]}" "$file"
    fi
done < <(find "$DEST" -type f -print0)
