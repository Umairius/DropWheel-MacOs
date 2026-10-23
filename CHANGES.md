# DropWheel redesign: what's in this drop

**Not compiled.** I can't run Swift here. Everything below was written against your existing code and
reviewed by hand; the first build may throw a few errors. Paste them back and I'll fix them.

## How to use it

1. Replace your `Sources/DropWheel/` folder with the one in this zip (it is the complete set, including the files I did not touch).
2. `Package.swift` and `build_app.sh` don't change. The font is embedded in Swift, so there is nothing to bundle.
3. Build and run as usual. First launch shows the new tutorial.

## What changed

**Wheel** (`WheelPanel.swift`, rewritten)
- Bigger: Standard is 520 pt (was 380). Compact 420, Large 640, Extra large 760. Menu: Appearance > Wheel size (it previews the wheel when you pick).
- Real frosted glass behind it (NSVisualEffectView), so Finder icons stop bleeding through.
- Bloom animation: segments grow in clockwise. Hover: the segment pops outward, its icon scales up and the segment tints in its family colour.
- Hover pill just outside the rim: "Convert to JPG / keeps original". The drag ghost covers the centre, so this is the readout that always works. The centre shows the end-result icon while you hover.
- Commit flash: chosen segment pulses, the rest fade, then the wheel fades out.
- Accessibility: Reduce Motion (no animation), Reduce Transparency (opaque, no glass), Increase Contrast (white outlines), VoiceOver segments, labels never below 12 pt, text labels under every slice if you switch "Label every slice with words" on.
- Sounds untouched. Haptic tick on every segment change, firmer click on commit, buzz on failure (trackpad only, switchable).

**Icons** (`IconKit.swift`, `IconData.swift`, `Brand.swift`, `FontData.swift`)
- All 34 end-result icons: page + format badge, glyph per content type. Outline (default) or solid; family colours or calm white.
- Badge text is contrast-checked (white on a deepened fill, 4.5:1) and condensed to fit, never shrunk.
- Font: Bricolage Grotesque (SIL OFL, licence in `Assets/Font/OFL.txt`), embedded, width axis used to condense long words like COMPRESS.
- `Tools/` has the generator: edit glyphs in `icons.js`, run `node gen_swift.js`, replace `IconData.swift`.

**Result toast** (`ResultToast.swift`)
- Working state while converting, then a card: the new file (drag it anywhere), Show, Undo. Errors shake and offer Details.
- The new file is selected in Finder (only if Finder is what you're looking at, so dragging from another app never yanks you away).
- Undo: new files go to the Trash; in Replace mode the original comes back from the Trash.
- Menu: Feedback > "Show a card when a file is ready" and "Select the new file in Finder".

**Tutorial** (`Tutorial.swift`)
- Shows after setup (or straight away if nothing needs downloading). A real practice picture, a Shift key cap that lights up when you press it, the JPG slice pulses in the wheel, and a nudge if you drag without holding the key or let go off the slices.
- Menu: "Try it: show the tutorial…" any time.

**Small edits to existing files**
- `Converter.swift`: `ConversionResult.trashed` remembers where "Replace" sent originals (for Undo). 6 lines.
- `SetupWindow.swift`: `onDismiss` hook so the tutorial can follow setup. 4 lines.
- `App.swift`: new settings, wiring, menus. Every original function is still there.

## Nothing gets deleted (audited)

Read all 30 places in the code that can remove, trash or replace a file. Full table: `DELETIONS.md`;
`Tools/audit-deletions.sh` re-checks it and fails if a new one ever appears.

- **No call touches an original you drag in**, except "Replace" mode (off by default), which moves the original to the **Trash**, and only after the new file exists and is not empty.
- Everything else is DropWheel cleaning up files it made itself seconds earlier: half-written output of a failed conversion, temp files, extraction staging, its own helper downloads. Output paths come from `uniqueOutput`, which only returns a path that doesn't exist yet.
- What I changed for this:
  - Tutorial: my first version wiped its practice folder. Now it deletes nothing; practice files live in the system temp folder.
  - Undo: moves only the files that conversion just made, only if unchanged since (edited, renamed or moved files are left alone), and only to the Trash.
  - ffmpeg now runs with `-n` (never overwrite) instead of `-y`.
  - Signing's "Delete it" button is now "Move it to the Trash".
  - Replace mode refuses to trash an original if the result is an empty file.
- Left as is, on purpose: `SignatureStore` removes its own plaintext signature file after the encrypted copy is safely written (otherwise a plaintext copy stays on disk).

## Behaviour you should know about

- Positions are still an equal split, so PDF's slot moves with the file type. The fixed-sector layout is not in this pass.
- Tutorial practice files live in the system temp folder; macOS clears it, DropWheel never does.
- The result card appears where you dropped. It stays while the pointer is on it.

## Checked vs not checked

Checked: icon geometry (rendered the originals, then re-rendered through a port of the exact path/arc parser and compared; that caught a missing `s` curve command, now fixed), brace balance, no name collisions with your code, every original `App.swift` function still present.

Not checked (needs your Mac): compilation; the embedded font's width axis actually applying via NSFontDescriptor (falls back to the system font if not); bitmap scaling of the icon renderer; the frosted-glass mask; haptics; Finder selection timing; whether dragging the tutorial tile triggers the wheel the same as Finder drags.
