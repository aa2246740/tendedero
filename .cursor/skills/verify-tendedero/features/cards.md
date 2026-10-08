# Cards

Each hung screenshot is a card on the line. Cards are the user's work surface: copy to paste elsewhere, annotate, drag into an app or a Finder folder to keep it, or discard it to the Trash.

## Sub-features

- `copy` — single click copies the image to the clipboard
- `annotate` — press-and-hold (or right-click → Annotate/标注) opens the in-place annotate editor
- `drag-to-app` — drag onto another app's window shares the image
- `drag-to-folder` — drag onto a Finder folder saves/moves the file there
- `discard` — the × control trashes the file (inbox files only)
- `hover-info` — hovering a card shows filename/date tooltip

## How to get to it (user POV)

Reveal the line (hover top edge, menu "Show line", or Ctrl+Opt+T), then interact with a card directly.

## Driving it with computer + shell

Preconditions: baseline green; ≥1 card hanging (see `line.md` → `hang`).

- `copy`: click the card center once → pasteboard contains an image: `osascript -e 'clipboard info'` lists «class PNGf»/TIFF (capture stdout in `files-<n>.txt`).
- `discard`: hover the card → the × appears (screenshot) → click × → card gone (screenshot) AND the file is in `~/.Trash` (`ls ~/.Trash | grep <name>`) — the pair is the proof.
- `drag-to-folder`: open a Finder window on a scratch folder, left_click_drag from the card to the folder → file exists at destination (`ls`); card drops.
- `annotate` / `drag-to-app` / `hover-info`: mark UNTESTED unless a run specifically exercises them — they are pointer-gesture paths that need a composed drag/press.

## Gotchas

- × only exists while hovering the card — a click at its coordinate without the hover does nothing; take the hover screenshot FIRST.
- Discard only trashes files living in the inbox folder; a card viewing a Desktop file has no × (by design — "files elsewhere stay the user's").
- Copy puts the IMAGE on the pasteboard, not the file URL — `clipboard info` evidence beats guessing from Finder paste.
- Annotation opens an in-place panel: dim backdrop, image centered, pill toolbar (马赛克 mosaic / 涂抹 smear / 画笔 pen / 文字 text / 撤销 undo / 取消 cancel / 完成 done). Fast — no system extension.
- Mouse: drag with a tool to paint; text tool → click, type, Return. Esc cancels, Return/完成 saves back to the same file and the card thumbnail refreshes.
- Cancel/取消 leaves the file byte-identical (check `ls -la` mtime). Done/完成 rewrites it atomic — same folder, same name.
