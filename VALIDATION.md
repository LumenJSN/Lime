# Validation

Apple Swift 6.4 (language mode 5), universal (arm64 + x86_64), macOS 13 deployment target, built on macOS 27.0.1. The automated suites were last run on arm64 on 2026-10-23; the live checks below date from Lime 1.0 (2026-10-19).

## Automated (`./test.sh`)

| Suite | Result | Covers |
|---|---|---|
| InteractionChecks | 521/521 | Route count = 269, 27 core tools, 6 actions; per-format and mixed-selection tool lists; wheel geometry (petal 0 at north, clockwise order, hole/outside/gutter dead zones, petal paths); controller hover/commit/cancel/mode switch/keyboard; drag-watcher state machine (stale pasteboard ignored, tap edge trigger, mode switching, mouse-up end, paused monitoring, custom key chords); untrusted content (link/image schemes, package path containment, parser-based EPUB sanitising, ffmpeg input guards); which streams are copied untouched and which clips can be joined without re-encoding; loudness measurement parsing; parallel file limits |
| ConversionMatrixChecks | 269/269 routes | Every conversion route, with RAR/PPT/XLS samples from `Tests/Fixtures`; outputs decoded (ImageIO, PDFKit, `unzip -t`, IWA text storage for Pages); Pages list numbering check |
| ToolChecks | 70/70 | All tools with real fixtures, including Copy Text (OCR on an image and an image-only PDF, Korean + English), Remove Background (transparent corners, opaque subject), target-size compression, animated WebP compression (frames kept, resize rejected), metadata write-back, annotations, crops, blur/solid redaction, collage, joins, splits, audio visualizer, channel conversion, bleeps, PDF organizing, QR reading, archive traversal rejection, symlinks removed from document packages, concat lists disguised as video refused; joined picture length, including clips with different time units; parallel files (cap, progress, file order, errors, cancelling, shared slots); WebP transparency |

No other application is launched.

Content round trips checked by hand: Markdown → DOCX → Markdown/HTML keeps headings, lists and tables; PDF → Markdown keeps headings and lists; multi-sheet XLS → CSV keeps formula results.

## Rendered UI

`Lime.app --render <dir>` draws the wheel (convert/tools/actions, glass/solid, light/dark), all settings tabs, the intro window, the progress card, the shelf and the editor windows.

## Live checks with synthesised input (Accessibility granted)

These were run on 2026-10-19 before the wording and design pass. That pass changed labels, names and drawing only; the automated suites above were re-run afterwards.

- Real drags from a helper drag source with Shift/Command/Control taps opened the wheel in 30/30 consecutive drags. Drops produced MP3, MP4, DOCX, PDF, PNG, XLSX, TAR, VTT, TXT, PPTX and Pages files, including two-file selections.
- The drop arrives after the mouse-up that ends a drag, so the wheel waits 0.6 s for it (regression checks in InteractionChecks).
- Editors were driven in the running app: bleep add/move/resize/Delete/context menu and saved output; split with a removed piece exported as one 2.02 s video; redaction lanes, "Redact from here", "Keep for Whole Video" and saved output; annotation Clear Drawing, loupe zoom, text width handles, ⌘V paste, placement outside the photo ignored, saved output; shelf rubber-band selection on the first drag.
- Copy Text on a PNG and a scanned PDF copied both lines (Korean + English) to the clipboard. Remove Background on a real photo (`/Library/User Pictures/Animals/Parrot.heic`) produced a clean cutout. The first recognition after launch takes about 15 s while Vision loads its models; later ones take about a second.

## Not exercised automatically

- AirDrop delivery, login-item registration, Terminal/iTerm2 launch.
