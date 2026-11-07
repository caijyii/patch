# Usage guide

[简体中文](usage.md) · [English](usage.en.md)

See the [installation guide](install.en.md) for setup and updates, and the [release notes](release-notes.en.md) for version changes.

## Scrolling captures

- Hover to identify a window and click to select it, or drag a region. Press `R` for free selection or `W` for window selection.
- Start a scrolling capture from the regular screenshot toolbar to capture the same region again. Existing annotations require confirmation before clearing; canceling keeps the original screenshot.
- Scroll automatically or manually. You can finish, save, pin, extract text, or annotate at any time. Unmatched frames are skipped; automatic mode switches to manual so you can continue scrolling or export the existing result.
- Confirming Reselect starts a new capture. Press Esc to keep the previous result and return to the paused state.
- Captures retain the original pixels and support lossless PNG export. Dynamic layouts or multiple scrollable areas may not stitch reliably; fixed headers and overlays may remain or repeat. At the memory budget or height limit, save the current result before starting another segment.

## Desktop pins

- Pin images or editable text to the desktop, including other apps' full-screen Spaces. New pins appear near the pointer.
- Images keep their aspect ratio. Large images initially fit within half the available screen width and height. Zoom with two-finger scrolling, the mouse wheel, or pinch gestures, then drag the whole image to view it. Copy, save, and text recognition use the original pixels.
- Text pins fit their content width. Long text wraps and expands fully without internal scrollbars, initially staying within half the available screen width and height. Zooming preserves styles and line breaks. Drag enlarged text to view it; while editing, use the toolbar's move handle or Option-drag.
- Double-click a text pin or choose Edit Text, then select text to adjust color, font size, bold, or italic, with undo support. Finishing copies all text and styles; a separate Copy action prioritizes the selection.
- Finishing image annotations automatically copies the result. New annotations are not automatically selected: style changes affect future annotations unless you explicitly select an existing one.
- Click an image pin to activate Patch before pinching. After switching to another app, click the pin again. Scroll-wheel zoom works directly.
- Pinning new content does not restore hidden pins. Show All Pins restores only the most recently hidden group at its previous positions.
- Deleting or clearing history does not close existing pins. Quitting Patch closes all pins.
- On the home screen, open More Settings → General for the separate Hide desktop pins in screenshots and Hide desktop pins in recordings switches. Both default to on and are saved automatically. Turn off screenshot hiding to include visible image and text pins in regular and scrolling captures; manually hidden pins stay hidden, and operation overlays remain excluded.

## Clipboard history

- Patch reads the current clipboard at startup and automatically collects images, plain and basic rich text, video files copied in Finder, and recordings saved through Patch while running. Collection has no toggle and cannot detect all sensitive content.
- History stays only in process memory, is not written to disk, and is cleared on quit. Closing the home window leaves Patch running and collecting in the menu bar; choose Quit from the Patch menu to exit.
- Text color, size, bold, and italic survive history previews, copying, and repinning. Changes to text or styles create a new entry; identical content and styles remain deduplicated.
- Filter by images, text, or videos. Click an image or text card to pin it, or a video card to open it in the default app. Each record can be copied or deleted directly.
- Clear removes only the selected category. Select All to clear every category.
- Batch pinning uses recent images and text, regardless of the current filter. The default is 5 items, adjustable from 1 to 20 in More Settings.
- Video records retain only file references and thumbnails. Deleting a record does not delete the video. Copy the file again if it has been moved, deleted, or become inaccessible.
- Text, images, and videos are limited to 100, 20, and 5 items respectively. Each category may evict its oldest records sooner if its memory limit is reached. See the [privacy notice](privacy-policy.en.md) for limits and data handling.

## Screen recording

- Recording begins after the save location and permissions are confirmed, followed by a three-second countdown. System audio and microphone input can be enabled separately.
- Pause and resume are supported. Paused time is excluded, and the result is saved as one MP4.
- Hiding the control window keeps recording; use Show Controls in the menu to restore it. Closing the control window stops and saves the recording.
- Pause, resume, or stop from the Patch menu, or stop with macOS's menu bar recording control. The control window, region border, and outer mask are excluded from the video.
- Turn off More Settings → General → Hide desktop pins in recordings to include visible pins, including image and text pins added during recording. Other Patch feature windows remain excluded. The preference applies to the next recording and stays fixed across pause and resume; it does not control other recording apps.
- If saving fails, recording segments are retained and the control window reappears so you can retry.

## Stickers and settings

- Drag stickers in the More panel to reorder them. The order is saved across launches; the toolbar shows the first designs that fit.
- Appearance can follow the system or use light or dark mode. Your choice is saved.
- The interface supports Simplified Chinese and English and follows the system by default; other system languages use English. Language changes in More Settings take effect after restarting. Original screenshots and clipboard content are not translated.

## Permissions and quitting

- Screen, microphone, and accessibility / device control permissions are requested as needed. Restart Patch if a granted permission has not taken effect.
- Closing the home window leaves Patch running in the menu bar. Choose Quit to end the app and clear the session's history and pins.
- The Dock icon remains while feature windows are open or minimized. Closing all of them returns Patch to menu-bar-only operation.
