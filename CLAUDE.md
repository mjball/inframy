# Inframy: notes for Claude Code

Inframy is a native macOS app that manages Matt's own photos as art on his Samsung **The Frame** TV
(2020 model, 55", white bezel) over the local network, replacing the SmartThings workflow.

- **Full plan:** `docs/SPEC.md`. Read the section for the current phase before writing code.
- **TV protocol:** `docs/PROTOCOL.md`. Everything there is reverse-engineered secondhand until verified
  against Matt's TV. Record verified facts there with raw request/response JSON (tokens redacted).
- **Current phase:** all four phases are built; next is verifying Phases 2 to 4 on the real TV with Matt and working
  through `docs/OPEN-QUESTIONS.md`. Protocol findings are in `docs/PROTOCOL.md`.
- **Cropping is always Matt's choice.** Never crop automatically; computer vision may only suggest a starting
  position (`CropSuggestion`). See `docs/SPEC.md` §4.

## Ground rules

1. **Native only.** Swift 6, SwiftUI, macOS 14+. No Python, Electron or web views in the app.
   Python is allowed only under `tools/` for probing the TV.
2. **Don't trust the protocol from memory.** The Art API differs by model year and firmware
   (e.g. API 0.97 uses a different upload transport than newer TVs). Verify against the real TV,
   then write it down in `docs/PROTOCOL.md`.
3. **The TV is a shared household device.** Read-only calls are always fine. Before any call that
   changes state on the real TV (upload, delete, change matte, slideshow settings, art mode on/off,
   selecting an image), say what you're about to do and get Matt's OK. Never delete content that
   Inframy didn't upload unless Matt explicitly confirms those specific items.
4. **One persistent connection per TV.** Don't open a connection per request; it can trigger the
   TV's pairing prompt.
5. **Secrets stay out of git and logs.** Pairing tokens go in the Keychain (app) or `tools/.tv-token`
   (probe, gitignored). Redact tokens in any logged or documented traffic.
6. **Originals are never modified.** Crops are stored as normalized rects; rendered JPEGs are cached
   and regenerated from originals.
7. **Logic lives in `InframyKit`** (Swift package, no UI) so it can be tested with `swift test`.
   The app target stays thin.
8. **Tests:** image pipeline output (exactly 3840×2160, sRGB, correct orientation), protocol framing
   (encode/decode against captured fixtures from the real TV), and sync diffing. TV client tests run
   against a fake local server, never the real TV.

## Target layout

```
project.yml                  # XcodeGen spec for Inframy.app (the .xcodeproj is generated, not committed)
App/                         # SwiftUI app target
Packages/InframyKit/         # TVClient, ImagePipeline, Library, Sync + tests
Packages/InframyKit/Sources/inframy-cli/   # CLI built on InframyKit (pair, info, ls, thumbs, upload, rm, shuffle)
tools/probe.py               # Phase 0 probe using the samsungtvws Python library
docs/SPEC.md, docs/PROTOCOL.md
```

## Commands (once scaffolded)

```
brew install xcodegen
xcodegen generate
xcodebuild -scheme Inframy -configuration Debug build
swift test --package-path Packages/InframyKit
swift run --package-path Packages/InframyKit inframy-cli info --host <TV_IP>
```

## Environment

- Run on Matt's Mac, on the same subnet as the TV (cross-subnet WebSocket connections fail).
- Ask Matt for the TV's IP; it should have a static DHCP lease.
- On the TV: Device Connection Manager → Access Notification → **First Time Only**, and enable
  **Power On with Mobile** (Wake-on-LAN). The first connection shows an Allow prompt on the TV;
  Matt has to press it with the remote.
