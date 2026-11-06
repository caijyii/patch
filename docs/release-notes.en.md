# Patch 0.1.1

[简体中文](release-notes.md) · [English](release-notes.en.md)

This update improves scrolling capture capacity and explains what to do when a limit is reached:

- Original pixels are preserved without reducing resolution. PNG export remains lossless.
- The stitching budget scales with physical memory, increasing its maximum from 128 MiB to 512 MiB. The height limit increases from 20,000 to 60,000 pixels. Actual capacity still depends on selection width and the memory budget.
- Separate messages explain memory, height, and oversized-region limits. At a limit, stitching stops, Continue is hidden, and automatic scrolling is disabled. Save or finish the current segment, then start a new capture from the remaining page content.
- Existing results remain available to save, pin, extract text, or annotate. Cancelling reselection or saving preserves the correct limit message.

Requires Apple Silicon and macOS 15+. Quit the old version and replace Patch.app in its existing installation location. Preferences are retained; permissions may need to be granted again. The app remains ad-hoc signed and is not notarized by Apple. See the [installation guide](install.en.md).

## Patch 0.1.0

This first stable release includes the following changes since Preview 5:

- Save, pin, or extract text directly from a scrolling capture. Annotated scrolling captures can also be pinned or used for text extraction.
- Start a scrolling capture from the regular screenshot toolbar. Scrolling selection recognizes windows by default and also supports dragging a region.
- Improved trackpad zoom interaction for image pins: click an image pin before pinching; scroll-wheel zoom continues to work directly.
- Consistent background lighting across the home screen, settings, clipboard history, recording, and text result windows.
- Updated DMG layout with drag-and-drop installation from Patch to Applications.
- Chinese and English README, release notes, installation guide, usage guide, and privacy notice.

Requires Apple Silicon and macOS 15+. DMG and ZIP installers are provided. The stable release label does not change its signing status: the app is ad-hoc signed, without a Developer ID signature or Apple notarization. See the [installation guide](install.en.md) for first-launch prompts and permissions.

Clipboard history and pins are cleared on quit. Scrolling captures may not stitch reliably with dynamic layouts or multiple scrollable areas. Historical changes are listed in the [Preview 5 release notes (Chinese)](preview-5-release-notes.md).
