# Headroom

macOS menu bar app (Swift Package, AppKit + SwiftUI, Sparkle updates). Sources in `Sources/Headroom`, tests in `Tests/HeadroomTests` (swift-testing).

## Build, test, run

- `swift build -c release` builds `.build/release/Headroom` (Sparkle.framework sits next to it, so it runs from there).
- `swift test` runs the unit tests. CI runs the same on every push to main.
- `./build.sh` builds the universal `build/Headroom.app`; `./build.sh install` also copies it to /Applications and relaunches it.
- `<binary> --snapshot <dir>` renders the menu bar strip and dashboard to PNGs after 8 s, waits for the first ledger refresh, then exits. Use it for benchmarks: `/usr/bin/time -l` on it gives CPU and peak memory footprint of one launch. Move `~/Library/Application Support/Headroom/claude-ledger.json` aside for a cold index and restore it afterwards.

## Release

1. Set both `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` to the new version, commit as `Bump version to x.y`, push main.
2. Create the release with notes, which also creates the tag:
   `GH_TOKEN=$(gh auth token -u sandrich) gh release create vx.y --repo sandrich/headroom --target main --title "Headroom x.y" --notes-file notes.md`
3. The Release workflow (`.github/workflows/release.yml`) builds, signs and notarizes the DMG, attaches it plus the Sparkle `appcast.xml`, and keeps the notes written at publish time. Pushing a tag `vx.y` without a release also works; then the notes are generated from the commits since the previous tag. Rebuild an existing release with the workflow's manual trigger and the tag.
4. Notes format used so far: `## What's new` bullets, then `**Full changelog**: .../compare/vPREV...vNEW`, then `Universal build for Apple Silicon and Intel, macOS 14 or newer. Signed and notarized by Apple.`

`gh` defaults to an account without write access to this repo; always prefix with `GH_TOKEN=$(gh auth token -u sandrich)`. Git push over SSH works as is.

## Ledger (token usage) design

Every provider scan must cost proportional to new data, never to total data, and must never load a whole file or row:
- Claude transcripts: tailed by byte offset through a memory-mapped line scanner, deduped on message id + request id. Hot files (modified in the last 2 h) are tailed every 10 s; a full stat pass runs every 5 min.
- Codex rollouts: same byte-offset tailing; the last `turn_context` model is carried per file.
- OpenCode: `session_message` rows hold the whole message (hundreds of MB), so only the head (model) and tail (tokens) are read with SQLite blob I/O, and only rows whose `time_updated` moved since the last scan.
- All of this state is persisted in `claude-ledger.json` (new fields are optionals so old caches still load); it is saved every 10 min and on quit.
