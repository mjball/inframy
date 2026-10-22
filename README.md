# Inframy

*Photos that will live in inframy.*

A Mac app for putting your own photos on a Samsung **The Frame** TV, without SmartThings.

Drop in photos from Finder or Photos, nudge a 16:9 crop if the automatic one isn't right, and Inframy does the rest:
it resizes to 3840×2160, uploads straight to the TV over your local network with **no mat**, keeps the TV's
shuffle pointed at your photos, skips duplicates, and shows you everything that's already on the TV so you can remove it.

## Status

Pre-alpha. Planning is done; building has not started. See [`docs/SPEC.md`](docs/SPEC.md) for the plan and
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) for what's known about the TV's art-mode API.

## How it works

The Frame exposes an undocumented local WebSocket "art app" channel. Open-source projects have reverse-engineered it
(see References in the spec). Inframy talks to it directly from your Mac. No Samsung account, no cloud.

## Disclaimer

Unofficial and not affiliated with Samsung. The API is undocumented and a firmware update could break it.
