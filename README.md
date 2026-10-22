<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/header/glow.svg?title=Lime&amp;subtitle=Drag+a+file%2C+tap+a+key%2C+pick+a+petal.&amp;logo=https%3A%2F%2Fraw.githubusercontent.com%2FLumenJSN%2FLime%2Fmain%2F.github%2Flime-icon.png&amp;accent=a3e635&amp;glow=a3e635&amp;align=left&amp;font=geist-mono&amp;border=false&amp;mode=dark" /><img alt="Lime" src="https://shieldcn.dev/header/glow.svg?title=Lime&amp;subtitle=Drag+a+file%2C+tap+a+key%2C+pick+a+petal.&amp;logo=https%3A%2F%2Fraw.githubusercontent.com%2FLumenJSN%2FLime%2Fmain%2F.github%2Flime-icon.png&amp;accent=a3e635&amp;glow=a3e635&amp;align=left&amp;font=geist-mono&amp;border=false&amp;mode=light" /></picture>
</p>

<p align="center">
  <a href="https://github.com/LumenJSN/Lime/releases/latest"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/github/release/LumenJSN/Lime.svg?variant=default&amp;size=sm&amp;color=65a30d&amp;logo=lu:Citrus&amp;logoColor=ffffff&amp;label=release&amp;mode=dark" /><img alt="latest release" src="https://shieldcn.dev/github/release/LumenJSN/Lime.svg?variant=default&amp;size=sm&amp;color=65a30d&amp;logo=lu:Citrus&amp;logoColor=ffffff&amp;label=release&amp;mode=light" /></picture></a>
  <picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/macOS-13%2B_Apple_silicon.svg?logo=apple&amp;variant=secondary&amp;size=sm&amp;mode=dark" /><img alt="macOS 13+ on Apple silicon" src="https://shieldcn.dev/badge/macOS-13%2B_Apple_silicon.svg?logo=apple&amp;variant=secondary&amp;size=sm&amp;mode=light" /></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/Swift-6.svg?logo=swift&amp;variant=secondary&amp;size=sm&amp;mode=dark" /><img alt="Swift 6" src="https://shieldcn.dev/badge/Swift-6.svg?logo=swift&amp;variant=secondary&amp;size=sm&amp;mode=light" /></picture>
  <a href="#features"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/conversions-269_routes.svg?logo=lu:Repeat&amp;variant=secondary&amp;size=sm&amp;mode=dark" /><img alt="269 conversion routes" src="https://shieldcn.dev/badge/conversions-269_routes.svg?logo=lu:Repeat&amp;variant=secondary&amp;size=sm&amp;mode=light" /></picture></a>
  <a href="#features"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/tools-27.svg?logo=lu:Wrench&amp;variant=secondary&amp;size=sm&amp;mode=dark" /><img alt="27 tools" src="https://shieldcn.dev/badge/tools-27.svg?logo=lu:Wrench&amp;variant=secondary&amp;size=sm&amp;mode=light" /></picture></a>
</p>

<div align="center">

A macOS menu-bar app: tap a key while dragging a file, and a wheel pops up to convert, edit or tidy it.

</div>

https://github.com/user-attachments/assets/c3fe106b-40b3-4420-bfbd-e6cb639224f9

## Getting started

1. Quit any other app that uses the same drag shortcuts, or the wheels will clash.
2. Open Lime (see [Install](#install)). A welcome window appears on first launch; after that, settings live in the menu-bar icon.
3. While dragging files in Finder, tap a key once:
   - **⇧ Shift**: convert wheel
   - **⌘ Command**: tools wheel
   - **⌃ Control**: actions wheel
4. The wheel stays up after you let go of the key. Drop on a petal to run it; drop in the centre or outside to cancel. Tap another key while the wheel is up to switch to that wheel.
5. Results are saved next to the original as `name.ext`. Tool results get a tag in parentheses, like `name (compressed).jpg`, and become `name (compressed) 2.jpg` if that name is taken. The original is never touched.

## Install

Requires Apple silicon and macOS 13 or later.

1. Download the latest `Lime-<version>-arm64.zip` from [Releases](https://github.com/LumenJSN/Lime/releases/latest) and unzip it.
2. Move `Lime.app` to `/Applications`.
3. Open it.

Lime is not notarized by Apple, so macOS may refuse to open it the first time ("Lime is damaged" or "Apple could not verify Lime"). Allow it in one of these ways, then open it again:

- **Terminal**: clear the download quarantine flag.

  ```sh
  xattr -dr com.apple.quarantine /Applications/Lime.app
  ```

- **System Settings**: after the warning, go to Privacy & Security, scroll down and click **Open Anyway** next to the Lime message. On macOS 14 and earlier, right-click `Lime.app` → **Open** also works.

Only do this for a copy you downloaded from this repository's Releases page. Each zip's SHA-256 is listed in the release's `SHA256SUMS.txt`.

### Updates

From 1.1.0 on, Lime checks for a new version once a day with [Sparkle](https://sparkle-project.org) and asks before installing it. Use **Check for Updates…** in the menu-bar menu to check now, or turn on **Install updates automatically** in Settings › About Lime. Every update is verified against Lime's EdDSA signature, so a tampered download is refused. Version 1.0.0 has no updater; download 1.1.0 once by hand.

## Features

- **269 conversion routes**: 8 image, 8 audio and 6 video formats plus GIF, PDF, DOCX/Pages/Markdown/RTF/RTFD/text clipping/TXT/EPUB, PPT/PPTX, XLSX/XLS/ODS/CSV/TSV, SRT/VTT and ZIP/TAR/GZIP/RAR. RAR, PPT, XLS, RTF, RTFD, text clippings and WEBM are read-only. The full table is in Settings › Conversions.
- **27 tools**: Compress (preset, target size or percentage), Metadata (edit/strip), Edit (21 sliders), Annotate (arrow, line, box, circle, text, pen, highlighter, numbers, magnifier, images), Background (12 gradients, 12 solid colours, or an image), Crop (aspect ratios or exact pixels), Read QR, Redact (automatic face and text detection), Normalize, Mute, Trim (auto-removes quiet edges), PDF Split/Organize/Merge, Create PDF, Extract, video Crop·Speed·Join·Snapshot·Split·Redact, Visualize, Channels, Bleep and Collage.
- **Editor windows**: Bleep and Redact ranges can be dragged to move and resized from either end. Right-click to choose "from here" or "whole clip", press Delete to remove one, or type start/end times in seconds. In Split Video, leave out the parts you don't want and save the rest as one video (Export as One Video) or as separate clips. Annotate has resize handles, adjustable text width, Clear Drawing, magnifier zoom and ⌘V image paste. Trim handles move 0.01 s per arrow key. Animated WebP keeps its animation when compressed.
- **Optional tools**: added to the end of the tools wheel. Turn them on or off with "Extra tools" in Settings › Basics.
  - **COPY TEXT**: recognises text in images, GIFs and PDFs on-device (Korean, English, Japanese, Chinese), copies it straight to the clipboard and shows a result window. PDFs with a text layer use it; only scanned pages are OCR'd. Saving produces `name (text).txt`. Works on several files at once.
  - **REMOVE BG**: finds the person, animal or object in a photo and makes a transparent PNG without the background (`name (no background).png`). Needs macOS 14 or later.
- **6 actions**: Shelf, Copy, Move, AirDrop, Copy Path and Terminal (opens Terminal or iTerm2).
- **Shelf**: a holding card with a lime tab on top. Drag it by its header, tab or edges to move it. Icon and list views, drag on empty space to select several, drag many files out at once, drop files in to add them, collapse, snap to screen edges, and Space for Quick Look.
- **Settings**: Basics (Liquid Glass/Frosted/Solid style — Liquid Glass on macOS 26 and later, launch at login, sound and haptics, key combo per wheel, Shelf behaviour, terminal app), Outputs (per-format quality, metadata, bit depth, compression, maximum video height, EPUB/Office layout), Conversions (format table), Access (save location, folder permissions) and About Lime.
- Progress cards, cancel, and click when finished to reveal in Finder.

## No other apps needed

Lime never launches Pages, Keynote, Numbers, Word, PowerPoint or Excel.

- **PPT/PPTX → PDF/JPG/PNG**: rendered with macOS's built-in Office preview renderer (Quick Look).
- **Reading Pages**: body text, headings, lists and bold/italic are read directly from the IWA archive inside the .pages file.
- **Writing Pages**: swaps the body of a bundled template to produce a real .pages file that opens in Pages as is.
- **XLS**: read with a built-in BIFF8 parser, falling back to Quick Look's table if that fails.

## Build and test

```sh
./Scripts/BuildMediaTools.sh   # once: builds ffmpeg/ffprobe from public sources into Resources/Tools
./build.sh   # produces ../Lime.app (fetches the pinned Sparkle release into .deps on first run)
./test.sh    # 349 interaction checks, 269 conversion routes, 55 tool checks
./Scripts/Release.sh   # ad-hoc signed zip, sources, checksums and a signed appcast item in ../dist/<version>
```

FFmpeg (LGPL), LAME, Opus, Vorbis, libvpx and libwebp are built from public sources by `Scripts/BuildMediaTools.sh`. Their licences are in `Resources/Licenses` (and inside the app). Each release also attaches the exact FFmpeg and LAME source archives it was built from. `Lime.app --render <folder>` draws the wheels, settings and editor windows as PNGs.

## Icon

Redraw it with `swift Scripts/MakeIcon.swift <folder>.iconset && iconutil -c icns <folder>.iconset -o Resources/AppIcon.icns`.

## License

Lime is released under the [MIT License](LICENSE). The bundled media tools and Sparkle keep their own licences; see `Resources/Licenses`.

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Please report security problems privately as described in [SECURITY.md](SECURITY.md).
