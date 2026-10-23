# Open questions for Matt

Written while Matt was away (2026-10-23). Each has the answer I assumed so work could continue.
Change any of these and I'll adjust.

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
   My Photos shuffle (at your last-used interval, default 15 min) if it's off. *Assumed: yes.*
4. **Shuffle interval menu.** The TV accepts any value, so the app offers 3 min, 15 min, 1 h, 12 h and 1 day.
   *Assumed: those are enough.* (Which values does the TV's own menu offer?)
5. **Finder files are referenced, not copied.** Photos dragged from Finder stay where they are (bookmarked);
   only Photos-app drags and picker imports are copied into ~/Library/Application Support/Inframy/Originals.
   *Assumed: you'd rather not duplicate files.* Downside: moving/deleting the original breaks re-renders.
6. **Removing from the Library doesn't touch the TV**, and deleting from the TV keeps the Library copy.
   *Assumed: they're separate actions.*
7. **Mac: desktop or laptop?** (Open question from SPEC §7, affects Phase 4 rotation.) *Assumed: a laptop that's
   often away from home*, so rotation runs opportunistically when the TV is reachable.

## Things only you can do

- **First launch of Inframy.app:** macOS will ask to allow local network access. Click Allow, or the app can't
  see the TV (the CLI is unaffected because Terminal already has access).
- **Photos access** (Phase 3 album sync) will prompt the same way.

## To verify on the TV (needs your OK)

- Phase 2 app: send a photo from the app, delete from the "On the TV" grid, shuffle toggle.
- Phase 2 app: drag a photo in from the Photos app (Finder drags and the picker are standard; Photos uses file
  promises, which I couldn't test without a mouse).
- The TV was asleep from ~11:00 while you were away, so the app's live-TV screens are untested on the real TV.

