# Prefs & quit

The remaining menu surface: Sounds, Open at login, Quit — plus the Ctrl+Opt+T hotkey and the promise that quitting restores the user's screenshot settings.

## Sub-features

- `sounds` — toggle peg/throw sound effects (checkmark, persists)
- `open-at-login` — SMAppService login item toggle (checkmark reflects real status)
- `hotkey` — Ctrl+Opt+T shows/hides the line from anywhere
- `quit` — menu "Quit Tendedero" (⌘Q) exits and restores `com.apple.screencapture`
- `welcome` — first launch reveals the line briefly + the inbox offer once
- `hang-clipboard` — "Hang clipboard image" copies a clipboard image (or selected image files) into the inbox and hangs it; disabled when the pasteboard has no fileURL/png/tiff
- `take-everything-down` — drops every card at once, files untouched; disabled when the line is empty

## How to get to it (user POV)

All in the status menu; the hotkey works globally.

## Driving it with computer + shell

Preconditions: baseline green.

- `sounds`: menu → "Sounds" → `defaults read app.tendedero.Tendedero soundOff` flips (the key is `soundOff`, INVERTED — absent/0 means sounds ON). Take a screenshot and hang another card — sound is audible, not assertable; checkmark + default is the proof.
- `open-at-login`: toggle → menu checkmark follows `SMAppService` status; cross-check `osascript -e 'tell application "System Events" to get the name of every login item'`.
- `hotkey`: `computer` key `ctrl+alt+t` → line shows/hides (screenshot pair).
- `hang-clipboard`: `screencapture -x -c` (copy to clipboard) or copy a PNG in Finder, then menu → "Hang clipboard image" → a card appears and the file (a `Dropped-*.png` or the copied-in file) is in the inbox.
- `take-everything-down`: with ≥2 cards, menu → "Take everything down" → cards fall; `pegged` is empty; files still on disk.
- `quit`: menu → "Quit Tendedero" → `pgrep` empty AND `com.apple.screencapture` back to baseline — same assertion as `inbox.md` → `restore-on-quit`.

## Gotchas

- `soundOff` is the persistence key, not `soundOn` — reading `soundOn` always returns 0 and proves nothing.
- `open-at-login` may silently fail without a signed Developer-ID build — verify the checkmark reflects reality on the NEXT menu open, not the click.
- The hotkey is `control+option`, not `cmd` — `ctrl+alt+t` in xdotool syntax.
- "Quit Tendedero" is the ONLY right way to end a verification run mid-flow; `kill -9` leaves `com.apple.screencapture` diverted and poisons the next run's baseline.
- `welcomed` in defaults suppresses the first-run offer — a reused home won't re-ask; `defaults delete app.tendedero.Tendedero welcomed` only between runs, never while it runs.
- Menu titles are rebuilt per open (`menuNeedsUpdate`) — a clipboard copied WHILE the menu is open does not enable "Hang clipboard image" until the next open.
