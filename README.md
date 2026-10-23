# Inframy

<img src="docs/images/app-icon-Default.png" width="128" alt="Inframy icon: a dusk landscape inside 16:9 crop brackets, the sun carrying an upload arrow">

*Photos that will live in inframy.*

A Mac app for putting your own photos on a Samsung **The Frame** TV, without SmartThings.

Drop in photos from Finder or Photos, pick the 16:9 area for each one, and Inframy does the rest:
it resizes to 3840×2160, uploads straight to the TV over your local network with **no mat**, keeps the TV's
shuffle pointed at your photos, skips duplicates, and shows you everything that's already on the TV so you can remove it.

## Status

Pre-alpha. The core library and a command-line tool work against a 2020 Frame; the app UI is next. See [`docs/SPEC.md`](docs/SPEC.md) for the plan and
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

