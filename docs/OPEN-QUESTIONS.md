# Open questions for Matt

Written while Matt was away (2026-10-23). Each has the answer I assumed so work could continue.
Change any of these and I'll adjust.

## Start here

**All four phases are built and merged** (PRs #4 to #7). The app is at `build/Inframy.app` (Release build; right-click →
Open the first time, since it's not notarized). 65 tests pass. **Nothing has been tried on the real TV since this
morning:** it went to sleep around 11:00, and I didn't wake it or change anything on it.

Suggested first run, about 10 minutes, with the TV on:
1. Open `build/Inframy.app` and click **Allow** when macOS asks about local network access.
2. Sidebar → On the TV: you should see MY_F0003 (the lake) marked "not from Inframy".
3. Drag `~/Downloads/IMG_0296.heic` into the Library, choose the same crop in the editor, then On the TV →
   **Find Matches** should propose linking it to MY_F0003.
4. Drop in two or three more photos, crop them (Return = accept & next), press **Send**. Watch the queue.
5. Look at the TV: full-screen, no mat, shuffling.
6. Settings (⌘,): look over Rotation and Photos album sync. Both are off until you turn them on.

What each phase added:
- **Phase 2:** library, crop editor (manual crops only; the suggestion just places the frame), send queue, On the TV
  grid with delete, and the Liquid Glass icon (docs/images/app-icon-*.png).
- **Phase 3:** adoption of photos already on the TV (perceptual-hash matches you confirm), "Frame" album sync,
  Settings window, per-photo sharpen.
- **Phase 4:** pool rotation, menu bar item, shuffle upkeep every 15 min, open at login.

## Ground rules I followed

- **No state changes on the real TV** while you were away (CLAUDE.md rule 3). Everything that writes to the TV
  was tested against the fake TV only. Real-TV checks are listed under "To verify on the TV" below.
- Commits, pushes, PRs and merges happened as usual.

## Questions (assumed answers)

1. **Icon.** Built as a Liquid Glass `.icon` (App/AppIcon.icon; preview in docs/images/app-icon-*.png): dusk sky,
   mountains and a lake, 16:9 crop brackets, the setting sun carrying an upload arrow. *Assumed: you like the
   direction.* Easy to tweak: colors, arrow size, bracket weight.
2. **Icon placard text.** For the "subtle wink at Samsung" I put a tiny gallery placard reading **"No. 86"**
   under the picture (to 86 = to throw out; also your TV's IP ends in .86). *Assumed: you like it.*
   Alternatives: "404", or no placard.
3. **Sending turns shuffle on.** SPEC §3 says Send "ensures shuffle is on", so after a send the app turns on
   My Photos shuffle (at your last-used interval, default 15 min) if it's off. *Assumed: yes,* but **only with 2+
   photos**: a 1-photo shuffle wedged the TV on 2026-10-23 (PROTOCOL.md).
4. **Shuffle interval menu.** The TV accepts any value, so the app offers 3 min, 15 min, 1 h, 12 h and 1 day.
   *Assumed: those are enough.* (Which values does the TV's own menu offer?)
5. **Finder files are referenced, not copied.** Photos dragged from Finder stay where they are (bookmarked);
   only Photos-app drags and picker imports are copied into ~/Library/Application Support/Inframy/Originals.
   *Assumed: you'd rather not duplicate files.* Downside: moving/deleting the original breaks re-renders.
6. **Removing from the Library doesn't touch the TV**, and deleting from the TV keeps the Library copy.
   *Assumed: they're separate actions.*
7. **Mac: desktop or laptop?** (Open question from SPEC §7, affects Phase 4 rotation.) *Assumed: a laptop that's
   often away from home*, so rotation runs opportunistically when the TV is reachable.
8. **Album sync is off by default.** Turning it on (Settings → Photos) triggers the Photos permission prompt.
   *Assumed: album name "Frame", import only (photos removed from the album stay in the library and on the TV).*
9. **Adoption threshold.** TV photos match library photos when their 64-bit dHash differs by ≤ 10 bits.
   *Assumed: fine to start; tune once there's real data.* Linking requires your click per pair.
10. **Sharpening is per photo** (checkbox in the crop editor) rather than global, so you can compare on the TV.
11. **Rotation is off by default** (Settings → Rotation). Defaults when you turn it on: keep 40 photos on the TV,
    rotate daily, swap 20% each time. *Assumed: you'd rather opt in before Inframy starts taking photos down.*
    The TV's capacity is unknown; if an upload fails on the TV's side, Inframy assumes it's full and shrinks the pool.
12. **Waking the TV for rotation is off by default.** Waking turns the screen on, possibly at night.
    *Assumed: not wanted unless you say so.*
13. **"Keep the slideshow on" is on by default.** If the TV's shuffle stops (or someone turns it off with the
    remote), Inframy turns it back on within 15 minutes while it's running. *Assumed: that's the point (SPEC §7).*
    If the household sometimes wants it off, untick it in Settings.
14. **Pinning.** Right-click a photo that's on the TV → "Pin on TV" to exclude it from rotation.

## Things only you can do

- **First launch of Inframy.app:** macOS will ask to allow local network access. Click Allow, or the app can't
  see the TV (the CLI is unaffected because Terminal already has access).
- **Photos access** (Phase 3 album sync) will prompt the same way.

## To verify on the TV (needs your OK)

- Phase 2 app: send a photo from the app, delete from the "On the TV" grid, shuffle toggle.
- Phase 2 app: drag a photo in from the Photos app (Finder drags and the picker are standard; Photos uses file
  promises, which I couldn't test without a mouse).
- The TV was asleep from ~11:00 while you were away, so the app's live-TV screens are untested on the real TV.
- Phase 4: turn on rotation with a small pool and check uploads happen before removals; check the menu bar item.

