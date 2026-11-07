# Patch

[![Version: 0.1.1](https://img.shields.io/badge/Version-0.1.1-6B8E6E?style=flat)](https://github.com/caijyii/patch/releases/tag/v0.1.1)
[![Platform: macOS 15+](https://img.shields.io/badge/Platform-macOS%2015%2B-607D8B?style=flat)](docs/install.en.md)
[![Architecture: Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon-607D8B?style=flat)](docs/install.en.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-6B8E6E?style=flat)](LICENSE)
[![Language: 中文 / English](https://img.shields.io/badge/Language-%E4%B8%AD%E6%96%87%20%2F%20English-6B8E6E?style=flat)](README.md)

[简体中文](README.md) · [English](README.en.md)

**Screenshots, scrolling captures, recording, annotations, and desktop pins—all in Patch.**

## Features

- **Screenshots**: Capture a region, window, or full screen, then copy or save it.
- **Scrolling captures**: Stitch captures with automatic or manual scrolling. Copy, save, pin, extract text, or annotate the result.
- **Screen recording**: Record a region and export to MP4, with separate controls for system audio and microphone input.
- **Annotations**: Add arrows, shapes, text, freehand drawing, pixelation, and original stickers. Edit scrolling captures and pinned images directly.
- **Desktop pins**: Keep images or editable text on the desktop. Zoom images, hide pins, and restore them.
- **Text recognition**: Recognize and copy Chinese and English text from screenshots.
- **Subject capture**: Detect image subjects and export transparent PNGs.
- **Clipboard history**: View, filter, and copy recent images, text, and video file references.
- **Custom shortcuts**: Assign up to two shortcuts to each action.

Content is processed locally, with no accounts, ads, or cloud uploads. The interface supports Simplified Chinese and English, with system, light, and dark appearance options.

## Installation

Requires **macOS 15+ and Apple Silicon (M-series chips)**.

- **Download**: Get the **DMG or ZIP** from the [GitHub release](https://github.com/caijyii/patch/releases/tag/v0.1.1). Open the DMG or extract the ZIP, then drag `Patch.app` into Applications. No developer tools are required.
- **Ask an agent to install**: Give your agent this instruction:

> Download the Patch installer compatible with my Mac from the GitHub Releases at https://github.com/caijyii/patch and install it.

The current release uses ad-hoc signing and is not notarized. You may need to confirm the first launch in System Settings. See the [installation and permissions guide](docs/install.en.md).

### Build from source

Install Xcode or Command Line Tools with Swift 6 support, then run this command in the project directory:

```sh
bash scripts/build-sandbox-app.sh
```

Output: `.build/distribution-check/Patch.app` (Patch Development). This is an ad-hoc signed local development build. Avoid running it alongside another Patch version. See [build and signing details (Chinese)](Distribution/README.md).

## Usage notes

- Permissions are requested as needed. Restart the app if a newly granted permission has not taken effect.
- While running, Patch automatically collects clipboard images, text, and video file references. Clipboard history and desktop pins are cleared when you quit. Closing the home window leaves the app running in the menu bar.
- Scrolling captures may not stitch reliably with dynamic layouts or multiple scrollable areas. Fixed headers and overlays may remain visible or appear more than once.

See the [usage guide](docs/usage.en.md) and [privacy notice](docs/privacy-policy.en.md).

## Default shortcuts

⌥ means Option; ⌘ means Command. Shortcuts can be changed on the home screen, with up to two per action.

| Shortcut | Action |
| --- | --- |
| ⌥1 | Screenshot |
| ⌥2 | Scrolling capture |
| ⌥3 | Subject capture |
| ⌥4 | Start / stop recording |
| ⌥5 | Extract text |
| ⌥6 | Pin clipboard content |
| ⌥7 | Clipboard history |
| ⌥8 | Pin recent items in a batch (5 by default) |
| ⌥9 | Hide / show all pins |
| ⌘Q | Quit (while Patch is in the foreground) |

## Recent updates

Longer scrolling captures preserve the original pixels. When the memory budget or height limit is reached, the app clearly explains why stitching stopped and prompts you to save the current segment.

See the [release notes](docs/release-notes.en.md).

## Feedback and contributions

Report bugs or suggest improvements through [Issues](https://github.com/caijyii/patch/issues), or email [caijyii@163.com](mailto:caijyii@163.com).

## License

[MIT](LICENSE) · Copyright © 2026 [caijyii](https://github.com/caijyii).

[Name and logo usage](BRANDING.md) · [Third-party notices](THIRD_PARTY_NOTICES.md) (Chinese)
