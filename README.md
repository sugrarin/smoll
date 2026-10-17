# Smoll

A small macOS app that compresses and converts files. Drop files into the window and they are replaced with smaller versions; the originals go to the Trash. It also adds **Make smoll** (jpg, png, pdf, mp4, mov) and **Convert to PDF** (doc, docx, rtf, ppt, pptx) to Finder's context menu.

## Features

- Compress jpg, png, heif, webp, mp4, mov and pdf
- Convert images to HEIF, JPEG, PNG or WEBP, and Office documents to PDF
- Limit width or height in pixels
- Four compression levels: Normal, Medium, Strong, Extreme
- Keep the original and save the result as "name smoll" instead of replacing it
- Re-run files from the window after changing settings

## Requirements

- macOS 14 or later
- Apple Silicon for hardware HEVC video encoding

Images and video work out of the box. PDF compression needs Ghostscript and Office conversion needs LibreOffice; Smoll installs them through [Homebrew](https://brew.sh) when you first need them.

## Install

Download `Smoll-*.zip` from [Releases](https://github.com/sugrarin/smoll/releases), unzip it and move `Smoll.app` to `/Applications`.

The app is not notarized. On first launch, right-click it and choose Open, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Smoll.app
```

## Build from source

```bash
./build.sh          # dist/Smoll.app
./build.sh install  # /Applications/Smoll.app
```

It needs the Swift 5.9 toolchain. The image tools are bundled from Homebrew on the first build, so run `brew install mozjpeg pngquant webp` first.

## Third-party software

Smoll has no Swift package dependencies. It uses Apple system frameworks (SwiftUI, AppKit, AVFoundation, ImageIO) and runs these open-source programs as separate processes:

| Program | License | Used for |
|---|---|---|
| [mozjpeg](https://github.com/mozilla/mozjpeg) | IJG, Zlib, BSD-3-Clause | JPEG compression (bundled) |
| [pngquant](https://pngquant.org) | GPL-3.0-or-later | PNG compression (bundled) |
| [libwebp](https://developers.google.com/speed/webp) (`cwebp`) | BSD-3-Clause | WEBP conversion (bundled) |
| [Ghostscript](https://ghostscript.com) | AGPL-3.0 | PDF compression (installed on demand, not bundled) |
| [LibreOffice](https://www.libreoffice.org) | MPL-2.0 | Office to PDF (installed on demand, not bundled) |

The bundled programs are unmodified Homebrew builds together with their libraries (libpng, libjpeg-turbo, little-cms2, libtiff, zstd, xz). Their licenses and source links are in `Smoll.app/Contents/Resources/Licenses`. Smoll's own code is not derived from them.

## Support

If Smoll is useful to you, you can support me: [ko-fi.com/sugrarin](https://ko-fi.com/sugrarin)

## License

[MIT](LICENSE)
