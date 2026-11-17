# Margins

A local Mac reader for PDF and EPUB built around Margulan Seisembai's reading method.

## Run
1. Open `Margins.xcodeproj` in Xcode 16 or newer (macOS 14+).
2. Press ⌘R.

Fallback without the Xcode project: `swift run` in this folder.

## Use
- Drop a PDF or EPUB on the library, or press +.
- Select text, then pick a colour (or ⌘1–⌘5): Proteins, Carbs, Fats, Fiber, Vitamins.
- Type a note in the panel on the right. Click a highlight to jump to it.
- ⇧⌘R opens the report: everything grouped by nutrient, proteins as a checklist,
  copy or export as Markdown. "Mark as Finished" signs and dates the book; two reads make it a Classic.

- Point at a highlight to see the note you wrote on it.
- Type a hashtag such as `#focus` in a note to file the passage under an idea. Passages that
  share an idea are connected across books: the notes panel shows how many others there are,
  and Ideas (⇧⌘I) in the library shows the graph and a page per idea.
- The timer in the reader toolbar counts reading time (click to pause). Reading Time in the
  library shows today, the last 7 days, all time, your streak and time per book.

To install it as a regular app in Applications, run `bash install.sh`.

Everything is stored in `~/Library/Application Support/Margins`.

## Your data is protected
- Every field in `library.json` falls back to a default if it's missing, so adding a
  field in a new version doesn't make old files unreadable. When you add a field to
  `Book` or `Highlight`, add a line for it in the decoders at the bottom of `Models.swift`.
- If the file can't be read anyway, Margins shows a "Library Not Loaded" screen and saves
  nothing, so the file is never overwritten. A copy goes to `Backups/unreadable-….json`.
- Margins never replaces a library that has books with an empty one, unless you
  deleted the last book yourself.
- `library.previous.json` holds the version from before the latest save.
- `Backups/library-YYYY-MM-DD.json`: one copy per day the app is opened (last 60 kept).
- `Backups/before-install-….json`: made by `install.sh` before every update.

To restore, quit Margins and copy any backup over `library.json`.

