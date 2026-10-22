# Contributing to Lime

Thanks for helping. Bug reports, conversion ideas and pull requests are all welcome.

## Reporting a bug

Open an issue with the **Bug report** form. Say which Lime and macOS version you use, which wheel style (Liquid, Frosted or Solid), and the exact steps. If a conversion fails, mention the source format and size.

Don't attach personal photos or documents. A small test file that shows the problem is best.

Security problems go through the private form instead; see [SECURITY.md](SECURITY.md).

## Building

You need an Apple silicon Mac with macOS 13 or later and the Xcode command-line tools (`xcode-select --install`).

```sh
./Scripts/BuildMediaTools.sh   # once: builds ffmpeg/ffprobe from public sources into Resources/Tools
./build.sh                     # builds ../Lime.app
./test.sh                      # interaction, conversion-matrix and tool checks
```

There's no Xcode project; `build.sh` calls `swiftc` directly, so any editor works.

## Pull requests

1. Fork the repository and branch from `main`.
2. Keep each pull request to one change, and match the style of the code around it.
3. Add or update checks in `Tests/` for anything that changes behaviour.
4. Run `./build.sh` and `./test.sh`; every check should pass.
5. Use a short, conventional commit message, such as `fix: keep the Shelf on screen` or `feat: add AVIF to the convert wheel`.

A few rules Lime keeps:

- **Originals are never touched.** Results are written next to the source with a new name.
- **Everything runs on the Mac.** Conversions and tools must not make network calls; the only one is Sparkle's update check.
- **No new heavy dependencies.** Media work goes through the bundled ffmpeg or Apple frameworks.

## Licence

By contributing, you agree that your work is released under the [MIT License](LICENSE).
