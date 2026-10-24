# Inframy spec

Last updated: 2026-10-22

## 1. Goal

Make putting personal photos on The Frame as easy as: **pick photos → (optionally) nudge the crop → done.**
Inframy handles everything after that and gives a far better view of what's on the TV than SmartThings does.

### The workflow it replaces

Today, for every photo, Matt has to:

1. Crop to 16:9.
2. Resize to the TV's pixel dimensions.
3. Transfer it to his phone.
4. Upload through the SmartThings app.
5. Remove the mat Samsung adds by default.
6. Make sure it's in the collection the TV shuffles.

It's slow, error-prone and doesn't scale to many photos. SmartThings is also unreliable at even loading.

### Non-goals (for now)

- Art Store content, other Samsung TV features, remote control.
- iOS/iPad versions.
- Multi-user or cloud sync.
- App Store distribution. This is a personal tool; local signing or Developer ID is fine.

## 2. Hardware and constraints

- **TV:** Samsung The Frame 3.0, 55" QLED 4K, 2020 model (LS03T series), white bezel. Panel is 3840×2160.
- **Art API version: `2.03`** (verified Phase 0). That's the newer family: d2d socket transfers, not the 2019
  `0.97` WebSocket-binary upload. Slideshow uses the **older** command names (`get/set_auto_rotation_status`).
- **No internet, by design.** The TV is on the main LAN with a static IP (`192.168.5.86`) whose gateway is itself,
  so it can't reach the internet (no ads, autoplaying channels, or firmware updates). Consequences: SmartThings
  can't reach it, its clock may drift, and SSDP discovery stops working (Bonjour still does).
- **Storage is small.** One 2020 LS03T owner reported ~259 MB free after installing a few apps. Plan for the
  TV holding tens of photos, not thousands (see pool rotation, §7).
- **Reachability:** TV must be on, in Art Mode, or in standby with network standby enabled. Same subnet as the Mac.
- **Slideshow reliability:** 2020 owners report the art slideshow sometimes stops; Inframy should re-assert it.

## 3. Target experience

1. **Find the TV automatically.** Bonjour (`_samsungmsf._tcp`), confirmed via REST `FrameTVSupport`; Matt never
   types an IP. Manual IP entry exists only as a fallback. On Matt's TV the art channel needed no token; if a
   TV does issue one, it goes in the Keychain.
2. **Import.** Drag photos from Finder or Photos into the window, use a Photos picker, or (Phase 3) designate a
   Photos album ("Frame") that Inframy keeps in sync.
3. **Crop.** Matt picks the 16:9 area for every photo in a fast crop editor (§4). Inframy never crops on its own:
   computer vision only suggests where the frame starts.
4. **Send.** One button. Inframy renders, dedupes, uploads with no mat, and ensures shuffle is on for the TV's
   personal-photos collection.
5. **See the TV.** A grid of what's actually on the TV (thumbnails), marked as Inframy-managed, adopted (matched to a
   library photo), or unknown. Multi-select delete.

## 4. Crop editor (the headline feature)

Matt explicitly wants 16:9 cropping to be *super easy*. Requirements:

- **Aspect locked to 16:9.** The crop frame never changes shape. The image moves and scales under it, so it's one
  gesture, not corner handles.
- **Pan:** drag. **Zoom:** scroll wheel / pinch / `+` `-`. Minimum zoom = image fully covers the frame (no empty
  space, unless the photo is in "fit" mode, below).
- **No automatic cropping (Matt's call).** Every crop is chosen by Matt. A photo can't be sent until he has accepted
  its crop (or picked "Fit with blur fill"/"Skip"). There is no "accept all"; images that are already exactly 16:9
  need no crop and are only resized.
- **Suggested starting position:** the frame starts as the largest 16:9 rect centered on a suggested point: detected
  faces (with headroom), else Vision's attention-based saliency (`VNGenerateAttentionBasedSaliencyImageRequest`),
  else the image center. Show the suggestion as a subtle marker so it's clear it's only a hint.
  (`CropSuggestion` in InframyKit.)
- **Batch flow:** a filmstrip of pending photos. Keys: arrows nudge the crop, `Return` = accept and go to next,
  `Space` = full-screen preview, `R` = reset to the suggested position. Accepting the suggested position is still one
  keystroke (`Return`), but it's always an explicit choice per photo.
- **Preview as on the wall:** show the crop inside a white bezel at TV proportions.
- **Quality warning:** if the crop region is narrower than 3840 source pixels, show a badge with the effective
  resolution (e.g. "upscaled 1.6×") so Matt can zoom out or skip it.
- **Portrait and square photos:** per-photo mode: *Crop* (16:9 slice, default), *Fit with blur fill*
  (blurred, darkened copy behind the sharp image), or *Skip*. A later option: pair two portraits side by side.
- **Non-destructive:** store the crop as a normalized rect + mode per photo. Re-editing is always possible;
  a changed crop means a re-upload (replace the old TV item).

## 5. Image pipeline

Core Image / ImageIO, in `InframyKit`:

1. Load original (file URL or PhotoKit asset data). Apply EXIF orientation.
2. Convert to **sRGB** (wide-gamut sources look washed out on the Frame otherwise).
3. Apply crop rect (or fit-with-blur composition).
4. Resize to **exactly 3840×2160** with a high-quality filter (Lanczos).
5. Optional light sharpening (off by default; make it a setting so it can be judged on the actual TV).
6. Encode JPEG, quality ~0.9, strip metadata (keep none: GPS etc. shouldn't go to the TV).
7. Cache the render keyed by (source hash, crop spec, pipeline version).

## 6. Library, ledger, dedup

Persistence: SwiftData or SQLite (GRDB), whichever the implementer prefers; keep the schema simple.

- **Photo:** id, source (security-scoped bookmark for files, or PhotoKit `localIdentifier`), source SHA-256,
  crop spec, render hash, status.
- **TVItem:** TV content id (e.g. `MY_F0096` / `MY-F0020`; format varies by firmware), first seen, linked Photo id
  (nullable), origin (`inframy` / `recognized` / `unknown`), thumbnail cache path.

Dedup rules:

- Importing the same source twice (same SHA-256 or same PhotoKit id) → no new Photo.
- Before upload, if a TVItem already links to this Photo with the same render hash → skip.
- **Recognition (was "adoption"):** on import and on every TV refresh, each TV item no library photo accounts for is
  checked against photos not yet on the TV as a *sub-image* of the uncropped original (multi-scale normalized
  cross-correlation; `SubImageMatcher`). A match (score ≥ 0.9) marks the photo "Already on your TV" and recovers
  the crop from the TV copy. It only changes Inframy's records, so it's automatic; "Not the Same Photo" undoes it and
  never pairs the two again. Never auto-delete unknowns.

## 7. Sync engine and pool rotation

- **Desired state** = set of Photos marked "on TV". **Actual state** = TV content list (personal category only).
- Diff → queue of uploads and deletes, executed serially with retries and backoff. The UI shows the queue.
- After uploads, ensure matte is none and shuffle is on for the personal-photos category.
- **Pool rotation (Phase 4):** the library can be much larger than the TV can hold. Setting: pool size N
  (e.g. 60). On a schedule (e.g. nightly, when the Mac and TV are both reachable), swap out a fraction of the pool
  for photos that have been off the TV longest. The TV's own shuffle handles minute-to-minute changes.
- **Storage full:** there's no known storage query. Treat upload failures that look like capacity errors as
  "full": shrink the pool and report it.
- **Background agent:** a menu bar item / login item that runs rotation and re-asserts shuffle. Wake the TV
  with Wake-on-LAN when needed.

Open question for Matt (affects rotation): is the Mac a desktop that stays on at home, or a laptop?
If a laptop, use a larger pool and rotate opportunistically when on the home network.

## 8. TV client (`InframyKit/TVClient`)

See `docs/PROTOCOL.md` for the wire format. Design:

- `actor TVConnection`: one WebSocket (`URLSessionWebSocketTask`) to port 8002 (TLS, self-signed: trust on first
  use and pin the cert) on the art-app channel. Request/response correlation by `id` / `request_id`.
  Auto-reconnect.
- Version negotiation on connect: try the new `api_version` request, fall back to `get_api_version`. Pick the
  upload transport and command names from the result.
- Uploads: legacy WebSocket-binary (API 0.97) or d2d socket via `Network.framework` (`NWConnection`, TLS when
  the TV says `secured`).
- Typed API: `contentList(category:)`, `thumbnail(id:)`, `upload(jpeg:matte:)`, `delete(ids:)`, `changeMatte`,
  `setShuffle(category:interval:)`, `artMode`, `currentArtwork`, `deviceInfo`.
- **Discovery (required):** Bonjour browse for `_samsungmsf._tcp` with `NWBrowser` (the TXT record's `se=` field
  has the REST URL); SSDP M-SEARCH as a fallback. Then `GET http://<ip>:8001/api/v2/` and keep
  `FrameTVSupport == "true"`. Needs `NSBonjourServices` (`_samsungmsf._tcp`) in Info.plist.
  Remember the TV by its stable device `id` / MAC, not its IP; on connection failure, re-discover and update the IP.
  If the TV is asleep, send Wake-on-LAN to the saved MAC, then re-discover.
- Wake-on-LAN helper (needs the TV's MAC; get it from the REST device info at `http://<ip>:8001/api/v2/`).

## 9. macOS specifics

- `Info.plist`: `NSLocalNetworkUsageDescription` (macOS will prompt for local network access),
  `NSPhotoLibraryUsageDescription` for PhotoKit.
- Start **non-sandboxed** for simplicity (personal tool). If sandboxed later: `com.apple.security.network.client`,
  user-selected file read access, Photos entitlement.
- Drag from Photos.app arrives as file promises: use `NSFilePromiseReceiver`.

## 10. Phases

Each phase ends with something Matt can use or verify.

### Phase 0: Probe the TV (no app code)

Run `tools/probe.py` (read-only by default) against Matt's TV and record results in `docs/PROTOCOL.md`:

- [x] TV found automatically (Bonjour; SSDP fails once the TV has no gateway).
- [x] Connection works. Art channel issued no token, so nothing to save.
- [x] Art API version reported: `2.03`.
- [x] Content list works; fields captured. The TV has no personal photos yet, so the `MY-` id format is still unknown.
- [x] Matte list; slideshow status via `get_auto_rotation_status` (`get_slideshow_status` → `-9`).
- [x] One thumbnail downloaded (d2d socket).
- [x] *With Matt's OK:* upload one test image with matte `none` → `MY_F0001` (d2d socket, plain TCP).
- [x] *With Matt's OK:* display an upload and confirm it's full-screen with no mat (`MY_F0002`; no cropping).
- [x] *With Matt's OK:* set shuffle on the personal category: `set_auto_rotation_status`, `type: shuffleslideshow`;
      any interval string is accepted (3/15/60/720/1440 and even 7). Restored to off.
- [x] *With Matt's OK:* delete the test images (`MY_F0001`, `MY_F0002`) via `delete_image_list`.
- [x] Capture raw JSON for each exchange (in `docs/PROTOCOL.md`; copy into test fixtures in Phase 1).

### Phase 1: CLI + core (InframyKit)

- [x] Scaffold: `project.yml`, app target (empty window), `InframyKit` package, `inframy-cli`.
- [x] TV client with pairing, version negotiation, list, thumbnail, upload (the transport Phase 0 proved),
      delete, change matte, set shuffle. Fake-server tests from Phase 0 fixtures. Bonjour discovery,
      certificate pinning (trust on first use), Wake-on-LAN.
- [x] Image pipeline with tests.
- [x] CLI: `pair`, `info`, `ls`, `thumbs <dir>`, `upload <files…> [--rect x,y,w,h | --fit]`, `suggest <file>`,
      `rm <ids…>`, `shuffle on|off [--interval]`. No automatic cropping: `upload` takes exact-16:9 images as-is,
      otherwise needs an explicit `--rect` (normalized) or `--fit`; `suggest` prints the suggested center/frame.
- [x] Read-only CLI commands verified on the TV (`discover`, `pair`, `info`, `ls`, `thumbs`).
- [x] *With Matt's OK:* `upload` + `shuffle on` on the real TV (2026-10-23): `IMG_0296.heic` (4:3) with Matt's
      approved `--rect` → `MY_F0003`, matte none, shown; shuffle every 15 min on `MY-C0002`.
- **Done when:** `inframy-cli upload photo.jpg` puts a mat-free, full-screen photo into the shuffle.

### Phase 2: The app (MVP)

- [x] Pair/connect UI with TV status (automatic: finds, pins and remembers the TV).
- [x] Import by drag-and-drop from Finder and Photos, and a Photos picker.
- [x] Crop editor per §4 (manual crops only; suggestion sets the starting frame).
- [x] "Send to TV" with progress queue.
- [x] "On the TV" grid with thumbnails and multi-select delete.
- [x] App icon (Liquid Glass `.icon`).
- [ ] Verified end to end on the real TV (pending Matt; see docs/OPEN-QUESTIONS.md).
- **Done when:** Matt can go from photos in Finder/Photos to shuffling on the TV without touching SmartThings.

### Phase 3: Library smarts

- [x] Ledger, dedup, recognition of pre-existing TV images (§6): sub-image matching against uncropped originals,
      automatic with "Not the Same Photo" to undo; crop recovered from the TV copy. Nothing is ever deleted
      automatically.
- [x] Photos album sync ("Frame" album, configurable in Settings; off until enabled). New album photos arrive
      as "needs crop"; edited versions are used.
- [x] Portrait modes (blur fill, skip): shipped in Phase 2's crop editor.

### Phase 4: Scale

- [x] Pool rotation (`RotationPlanner`/`Rotator`): pool size, interval and swap % in Settings; uploads before
      removals; only Inframy/linked photos come down; pinned photos stay; a TV-side upload failure shrinks the pool
      ("probably full"). Off until enabled.
- [x] Menu bar agent (`MenuBarExtra`) + Open at login (`SMAppService`).
- [x] Wake-on-LAN (menu, CLI `wake`; optional before rotation, off by default).
- [x] Shuffle re-assertion every 15 min while running ("Keep the slideshow on", on by default).
- [ ] Verified on the real TV (pending Matt).

## 11. Risks

- **Undocumented API.** Firmware updates could change it; Samsung removed and later restored it on 2022 models.
  A 2020 TV is unlikely to get big firmware changes, which helps.
- **Protocol version uncertainty** for this exact TV until Phase 0.
- **Reachability**: TV asleep or off the network; Wake-on-LAN may or may not wake it into a state where the
  art channel responds.
- **Slideshow quirks** on 2020 firmware (allowed interval values, stopping on its own).

## 12. References

- NickWaterton/samsung-tv-ws-api (Frame-focused fork; `samsungtvws/art.py` is the best protocol reference):
  https://github.com/NickWaterton/samsung-tv-ws-api
- samsungtvws on PyPI (3.0.6, Sep 2026; includes Art API 0.97 handling): https://pypi.org/project/samsungtvws
- ha-samsungtv-smart issues #307 / #311 (API 0.97 binary upload and thumbnails, with working code):
  https://github.com/TheFab21/ha-samsungtv-smart/issues/307
- framesmith (Rust library; ports, pairing, slideshow config): https://docs.rs/crate/framesmith/latest
- framectl (Go CLI; folder sync): https://pkg.go.dev/github.com/garyburd/framectl
- SAWSUBE (self-hosted app; image pipeline and dedup ideas): https://github.com/WB2024/SAWSUBE
- Samsung developer forum on 2022 firmware renaming commands:
  https://forum.developer.samsung.com/t/most-reliable-approach-to-manage-art-mode-images-on-samsung-frame-tvs/29155
