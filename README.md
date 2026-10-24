# Inframy

<img src="docs/images/app-icon-Default.png" width="128" alt="Inframy icon: a dusk landscape inside 16:9 crop brackets, with a flock of birds in the sky">

*Photos that will live in inframy.*

A Mac app for putting your own photos on a Samsung **The Frame** TV, without SmartThings.

Point it at an album in Photos, pick the 16:9 area for each photo, and Inframy does the rest:
it resizes to 3840×2160, uploads straight to the TV over your local network with **no mat**, keeps the TV's
shuffle pointed at your photos, skips duplicates, and shows you everything that's already on the TV so you can remove it.

## Status

Alpha. The app (library, crop editor, send queue, TV grid, menu bar item) and the command-line tool are
built; the core was verified against a 2020 Frame. See [`docs/SPEC.md`](docs/SPEC.md) §12 for what's
still to check. See [`docs/SPEC.md`](docs/SPEC.md) for the plan and
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) for what's known about the TV's art-mode API.

## How it works

The Frame exposes an undocumented local WebSocket "art app" channel. Open-source projects have reverse-engineered it
(see References in the spec). Inframy talks to it directly from your Mac. No Samsung account, no cloud.

## Disclaimer

Unofficial and not affiliated with Samsung. The API is undocumented and a firmware update could break it.

## Building

```
brew install xcodegen
xcodegen generate                                  # Inframy.xcodeproj (not committed)
xcodebuild -scheme Inframy build
swift test --package-path Packages/InframyKit
swift run --package-path Packages/InframyKit inframy-cli --help
```

