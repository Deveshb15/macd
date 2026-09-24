# mac'd

A minimal macOS menu bar app that shows CPU temperature, memory use, and free disk space,
and frees up space with a preview you can read before anything is deleted. Cleaning and
disk analysis are powered by a bundled copy of [Mole](https://github.com/tw93/Mole), so no
terminal or Homebrew is needed.

Requires macOS 15 or later. CPU temperature is supported on Apple Silicon.

## Develop

```bash
brew install xcodegen
scripts/fetch-mole.sh     # vendors the pinned Mole release into Vendor/mole
xcodegen generate         # creates Macd.xcodeproj from project.yml
open Macd.xcodeproj
```

Run the tests from Xcode, or with `xcodebuild test -project Macd.xcodeproj -scheme Macd`.

## Release

```bash
DEVELOPMENT_TEAM=ABCDE12345 NOTARY_PROFILE=macd-notary scripts/notarize.sh
```

This produces a signed, notarized, and stapled `build/macd.dmg`.

## Updating Mole

1. Change `MOLE_VERSION`, `MOLE_COMMIT`, and `SOURCE_TREE_SHA256` in `scripts/fetch-mole.sh`.
2. Run `scripts/fetch-mole.sh`.
3. Capture a fresh `mole clean --dry-run` and `mole analyze -json` output into
   `MacdTests/Fixtures/`, then run the tests. The cleanup preview parses Mole's text
   output, so a Mole update can break it. The fixtures catch that.

## License

mac'd bundles Mole, which is licensed under the GNU GPL v3. Mole runs as a separate
program and mac'd does not link its code. See `Macd/Resources/THIRD_PARTY_NOTICES.md`.
