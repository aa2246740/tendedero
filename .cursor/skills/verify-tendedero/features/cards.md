# Cards

Each hung screenshot is a card on the line. Cards are the user's work surface: copy to paste elsewhere, annotate in place, drag into an app or a Finder folder to keep it, share it, or discard it.

## Sub-features

- `copy` — single click copies the image to the clipboard; a "Copied" pill flashes on the card
- `annotate` — press-and-hold (~0.45 s) or right-click → Annotate opens the in-place editor (see `annotate.md`)
- `context-menu` — right-click shows Copy, Open, Annotate, Share…, AirDrop, Show in Finder; then, for inbox files: Save to Desktop, Discard — for files elsewhere: Take down, Move to Trash
- `share` — Share… opens the system share sheet; AirDrop goes straight to 隔空投送
- `hang-in` — drop an image file (or image data) onto a hanging card: it is COPIED into the inbox and a new card appears (the source never moves)
- `services` — Finder right-click → "Hang" (NSServices, localized 挂/掛/Colgar) does the same copy-in-and-hang; browsers never show Services, so for web images: right-click → Copy image → status menu → "Hang clipboard image"
- `save-to-desktop` — inbox files only: moves the file to ~/Desktop and drops its card
- `take-everything-down` — status menu item drops all cards at once (files untouched)
- `drag-to-app` — drag onto another app's window shares a copy; the card stays
- `drag-to-folder` — drag onto a Finder folder/Desktop moves the file there; the card drops
- `discard` — the × (top-left, hover only) discards: inbox files go to the Trash, others just leave the line
- `hover-info` — hovering a card lifts it slightly and shows the × and its tooltip

## How to get to it (user POV)

Reveal the line (rest the pointer on the t-shirt icon, menu → "Show line", or Ctrl+Opt+T), then interact with a card directly.

## Driving it with computer + shell

Preconditions: baseline green; ≥1 card hanging (see `line.md` → `hang`).

- `copy`: click the card center once → pasteboard contains an image: `osascript -e 'clipboard info'` lists «class PNGf»/TIFF (capture stdout in `files-<n>.txt`) AND the card shows the "Copied" pill in a screenshot taken <1.2 s after the click.
- `annotate`: covered by `annotate.md`.
- `context-menu`: `right_click` the card → screenshot the open menu; item set follows `context-menu` above (inbox file shows Discard; a Desktop file shows Take down + Move to Trash and no Save to Desktop).
- `discard`: hover the card → the × appears (screenshot FIRST) → click × at the card's top-left → card gone AND, for inbox files, the file is in `~/.Trash` (`ls ~/.Trash | grep <name>`) — the pair is the proof.
- `hang-in`: reveal the line, `left_click_drag` a scratch PNG from a Finder window onto a hanging card → `ls` shows a new file in the inbox (name deduped `stem-N.ext` on collision) and `pegged` lists it; the source file is untouched.
- `save-to-desktop`: right-click an inbox card → "Save to Desktop" → file lands on `~/Desktop` (`ls`) and the card drops.
- `drag-to-app` / `hover-info`: mark UNTESTED unless a run specifically exercises them — pointer-gesture paths that need a composed drag/press.

## Gotchas

- × only exists while hovering the card — a click at its coordinate without the hover does nothing; take the hover screenshot FIRST.
- Discard on an inbox file TRASHES it; "Take down"/"Move to Trash" appear only for files outside the inbox — menu labels depend on which file the card views.
- Copy puts the IMAGE plus the file URL on the pasteboard — `clipboard info` evidence beats guessing from a Finder paste.
- Drops only land while the line is revealed AND on a card (`hitRects`) — there is no drop zone on the rope or empty space.
- Press-and-hold fires at ~0.45 s and suppresses the click — for a `copy` click keep the press short; for annotate hold ≥0.6 s.
- AirDrop on a VM opens the real 隔空投送 sheet but reports Wi-Fi/Bluetooth off — expected, not a bug.
- Cards are SwiftUI and NOT in the AX tree — verify them from screenshots and `pegged`, never from accessibility nodes.
