# Clothesline

The core loop: every screenshot the user takes flies onto a rope pinned to the top edge of the screen. The line lives tucked above the menu bar like an auto-hiding Dock — it slides down when the pointer rests on the t-shirt icon or when opened on purpose, and tucks away when the pointer leaves. It only ever VIEWS files — it never moves or deletes them on its own.

## Sub-features

- `hang` — a new screenshot lands on the line (a 2.5 s peek + flight animation from where it was captured)
- `reveal` — resting the pointer on the status item for ~0.25 s slides the line down; leaving for ~0.5 s tucks it back
- `show-hide` — menu "Show line"/"Hide line" and Ctrl+Opt+T pin it open until the cursor has visited the line and left
- `menu-bar-away` — a click anywhere in the menu bar (any icon, any menu) puts the line away and keeps it away until the pointer leaves the bar
- `capacity` — past ~12 cards (fewer on narrow screens) the oldest drops off; the file stays on disk
- `prune` — deleting a hung file in Finder drops its card
- `empty-dismiss` — when the last card goes the line dismisses itself (~0.7 s) unless it was pinned open
- `wind` — idle cards sway slightly (visual only)

## How to get to it (user POV)

- Take a screenshot with the usual system shortcut (Cmd+Shift+3/4), or drop an image into the screenshots folder while Handle screenshots is on.
- Rest the pointer on the t-shirt icon in the menu bar, or open the status menu → "Show line" / press Ctrl+Opt+T.
- Click anything in the menu bar, or move the pointer onto other menu bar items, to put it away.

## Driving it with computer + shell

Preconditions: baseline green; inbox mode ON (menu → "Handle screenshots" checked) so `screencapture` output is accepted without the xattr question.

- `hang`: `screencapture -x ~/Library/Application\ Support/Tendedero/Screenshots/proof-<n>.png` → within ~1 s the line peeks down with a new card; the file exists in the inbox (`ls` before/after in `files-<n>.txt`) and `defaults read app.tendedero.Tendedero pegged` lists its path.
- `reveal`: `computer` mouse_move onto the t-shirt icon (~x=871,y=9 — read its position from a menubar screenshot first, it drifts) and wait ~0.5–1 s → screenshot shows the full line; mouse_move to (512, 400) and wait ~1 s → line retracted.
- `show-hide`: menu → "Show line" (title flips to "Hide line" on next open) → line stays while the pointer is elsewhere; it tucks after the cursor has visited the line zone and left.
- `menu-bar-away`: with the line revealed, move the pointer onto a DIFFERENT menu bar item (e.g. the clock, x≈1010,y=9) or click one → line tucks within ~1 s.
- `prune`: `rm` or trash a hung file → its card disappears; the path drops out of `pegged`.
- `capacity`: hang >12 files rapidly (`for i in $(seq 1 14); do screencapture -x <inbox>/cap-$i.png; done`) → screenshot shows ≤12 cards; `ls` still shows all files.
- `empty-dismiss`: trash every hanging file (or menu → "Take everything down") → the whole line slides away, no peek left.

## Gotchas

- The top EDGE is no longer the trigger: parking the pointer at y≈0–15 on empty menubar does nothing — only the status item itself reveals, and a menu-bar click suppresses hover reveal until the pointer exits the bar.
- On the Desktop (inbox OFF) a `screencapture`/copied file does NOT hang — no `kMDItemIsScreenCapture` xattr. Drive `hang` in inbox mode.
- Files older than app launch never hang (`launchDate` gate) — "why didn't my pre-seeded file hang" is by design.
- The watcher debounces ~0.2 s; rapid `screencapture` bursts are fine but assert after ≥1 s.
- Card positions depend on where the screenshot was taken from; assert on COUNT and presence, not pixel coordinates.
- `screencapture -x` writes synchronously but the OS may still finish metadata async — `sleep 1` before screenshotting the line.
- The panel only accepts the mouse over a photo (`hitRects`): drops must land on a CARD, not the rope or empty space — reveal it first.
- A pinned line ("Show line"/hotkey/welcome) untucks itself once the cursor has entered the line zone and left — it is not a permanent pin.
- While the Annotate editor is open the line is force-tucked and icon-hover is disabled — a line that "won't reveal" may have an editor open.
