# Annotate (in-place markup editor)

Press-and-hold a card (or right-click → Annotate) to mark the file up in place: a solid dark full-screen panel with the image fitted on it, a dark HUD toolbar under the image, and a hint line under the toolbar. Marks stay editable objects until "Done" writes them into the SAME file — atomically, through ImageIO with the original properties (DPI, color profile survive; JPEG quality 0.92). Cancel, or Done with no marks, leaves the file byte-identical.

## Sub-features

- `open` — press-and-hold (~0.45 s) on a card or right-click → Annotate opens the editor over the whole screen; the line tucks away and stays down while it is open
- `draw` — drag with a shape tool: Rectangle 1, Ellipse 2, Arrow 3, Pen 4; ⇧ squares/circles and 45°-snaps; a drawn shape stays selected; a sub-2 px drag or an arrow shorter than its own width leaves no mark
- `text` — Text 5 or Text box 6, click on the image, type (placeholder "Type…"); Esc / click-outside / ⌘⏎ finishes; ⏎ is a newline; empty text never becomes a mark; text box fills a colored rounded box behind auto-contrast text
- `brush` — Mosaic 7 and Blur 8 paint strokes (ring cursor) over a pixelated/blurred copy of the whole image; strokes are marks too — movable afterwards, and moving one reveals the correct pixels underneath
- `select-edit` — tool V (or any non-freehand tool) picks a mark: drag moves (⇧ axis-locks), handles resize (arrow has 2 end handles; text scales font from corners only; others get edge handles when big enough), ⌫ deletes, ⌘D duplicates, ←↑↓→ nudges 1 px (⇧=10); double-click a text re-edits it; the size and color controls restyle the focused mark live
- `undo-redo` — ⌘Z / ⇧⌘Z or the curved-arrow buttons; history is mark snapshots (≈100); while typing, ⌘Z undoes keystrokes, and ⌘Z with nothing left to undo drops a NEW text mark
- `zoom` — pinch, ⌘-scroll, ⌘=/⌘-, ⌘0 fit, ⌘1 actual size, double-tap toggles; scroll pans when bigger than the view, Space-drag pans by hand; a toast shows the % near the image's bottom edge
- `discard` — ✕ button or Esc: first Esc lets go of a selection; with marks, the next Esc shows "Press Esc again to discard your changes" and only a second Esc within 2 s throws the marks away; file untouched
- `save` — ✓ Done button (accent blue), ⏎ or ⌘S: composites marks at the file's own resolution and writes the same path; the card's thumbnail refreshes; Done with zero marks writes nothing

## How to get to it (user POV)

Reveal the line, then on a card: press and hold until it opens, or right-click → Annotate. There is no other entry point — the editor only opens on a hung file.

## Driving it with computer + shell

Preconditions: baseline green; ≥1 card hanging whose file you may overwrite (a `screencapture -x` fixture in the inbox); the line revealed and staying revealed while you hold the mouse on the card.

- `open`: `left_mouse_down` on the card center, hold ≥0.6 s, `left_mouse_up` → screenshot shows the dark backdrop, the image fitted, the toolbar pill under it. Alternative: `right_click` the card → click "Annotate". While open, the line is tucked (`line.revealed` false — hover on the icon does not bring it down).
- `draw`: press `1` (Rectangle) then `left_click_drag` across the image → a stroked rect in the current color; it is selected (accent frame + white handles). `defaults read app.tendedero.Tendedero annotateTool` records the last tool.
- `text`: press `5`, click the image, `type` ASCII (e.g. `TEST`), press Esc → the text is a mark. CJK cannot be typed by the `type` action into this field — do not mark CJK verified via it.
- `select-edit`: press `v`, click the rect → handles show; drag it; press `⌫` → mark gone. `⌘Z` brings it back.
- `undo-redo`: after a draw, `key cmd+z` → mark disappears; `key cmd+shift+z` → back.
- `discard`: with ≥1 mark, `key esc` → toast "Press Esc again…"; a second `key esc` within 2 s → editor closes; `ls -la <file>` mtime/size unchanged. Put BOTH `key esc` steps in ONE `actions` array — separate computer calls land >2 s apart and only re-arm the toast.
- `save`: after a draw, `key return` (or click ✓ Done) → editor closes; `stat -f %m <file>` bumped, `sips -g dpiWidth -g profile <file>` unchanged, `defaults read app.tendedero.Tendedero pegged` still lists the path, and the card shows the mark (screenshot).

## Gotchas

- Tool shortcuts are V + 1–8 in toolbar order (Select, Rectangle, Ellipse, Arrow, Pen, Text, Text box, Mosaic, Blur) — 5 is Text and 6 is Text box, easy to swap.
- Picking a color while on Select/Mosaic/Blur jumps back to the last ink tool — it is a feature, not a reset bug.
- The first Esc only clears a selection; do not count it as a discard attempt. With marks, two Esc presses inside the same 2 s window are required — batch them in one computer call, or a delayed second Esc just re-arms the toast and the editor stays.
- Clicking the backdrop around the image finishes text or drops a selection — it does NOT close the editor.
- Return/Enter commits and closes. Inside a text it is a newline — finish the text first.
- Dragging a mark requires the V tool or a non-freehand tool; on Pen/Mosaic/Blur a press starts a new stroke.
- Marks are objects, not pixels: a proof that only compares file bytes after "move + Done" shows a write even when the visible result is identical — check the mark list changed via the card thumbnail or a re-open.
- Persistence: `annotateTool`, `annotateLineSize`, `annotateTextSize`, `annotateColor` in `app.tendedero.Tendedero` — a restyled default leaks into the next editor session by design.
- The editor needs a TCC-free path only for the file itself — it edits the inbox file in place. No extra permission beyond the app's baseline.
