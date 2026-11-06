# Usage guide

[简体中文](usage.md) · [English](usage.en.md)

This guide describes the current source. For a released installer, refer to its release notes. See the [installation guide](install.en.md) for installation and updates.

## Clipboard history and settings

While running, Patch automatically collects clipboard images, plain text, and video files copied in Finder, as well as recordings successfully saved through Patch. Text is limited to 100 items / 8 MiB, images to 20 items / 128 MiB, and video references and thumbnails to 5 items / 8 MiB. Each category independently evicts its oldest items. Image accounting includes decoded pixels, PNG data, and thumbnails, so the memory limit may be reached before the item limit. History lasts only for the current session and is cleared when Patch quits.

## Working with history

Records are grouped by Today, Yesterday, or date and can be filtered by All, Images, Text, or Videos. Click an image or text card to pin it; click a video card to open it with the default application. Each record has copy and delete buttons. Videos are copied as file references.

Video history retains only the original file reference and a thumbnail, not a full cached video. If the file is moved, deleted, or inaccessible, Patch asks you to copy it again. Deleting records or clearing history does not delete the original video. Clear removes only the currently selected category, and the displayed count follows that filter.

Batch pinning uses the most recent images and text, regardless of the history panel's filter. The default is 5 items, adjustable from 1 to 20 in More Settings. New pins appear near the pointer. Appearance can follow the system or use light or dark mode; manual choices are saved.

## Full-screen desktops

Pins and their toolbars can appear in other apps' full-screen Spaces. Clicking an image pin or starting to drag it activates Patch so trackpad pinch gestures can work. After switching to another app, click the image pin again before pinching. Scroll-wheel zoom works directly. Showing a pin, editing text, or annotating an image inline does not by itself bring Patch to the foreground.

## Screenshot selection

Screenshot selection uses nonactivating overlays to avoid switching from another app's full-screen Space to Patch's desktop when the overlay opens or is clicked.

## Pin display and zoom

Image pins preserve the original aspect ratio. Small images retain their display size; large images initially scale down to fit within half of the available screen width and height. Two-finger scrolling, the mouse wheel, and pinch gestures can zoom the image. Drag the whole image to view it after zooming; there are no internal scrollbars.

Opaque images have small rounded corners and a thin border. Transparent subject cutouts have no added border. Zoom and rounded corners affect display only: copy, save, and text recognition use the original pixels. Text pins use a neutral background, small rounded corners, a thin border, and 16 pt body text. Their initial window also fits within half of the screen width and height. Text recognition results use 14 pt body text. Screenshot and pin toolbars use larger icons and hit areas on 1× displays, compact sizing on 2× displays, and wrap to fit the available space.

## Interface language

The interface supports Simplified Chinese and English and follows the system language by default; other system languages use English. Choose a language in More Settings and restart Patch to apply it. Screenshots and original clipboard content are not translated.

## Stickers and restoring hidden pins

Stickers are ordered by animals, yellow faces, weather, leaves, flowers, and other designs by default; the blue cat follows the cat. Drag items in the More panel to reorder them. The panel shows 32 designs in 8 columns and 4 rows; the toolbar shows the first designs that fit. The order is saved locally across launches. New designs are inserted next to their default neighbors while preserving the existing custom order.

Image and text pins and annotation windows use thin borders and soft shadows; transparent subject pins preserve their transparent outline. After hiding all pins, pinning new content individually or in a batch does not restore previously hidden pins. If you hide pins again, Show All Pins restores only the most recently hidden group at its previous positions; older hidden groups stay hidden. Deleting or clearing clipboard records does not close existing pins.

## Screen recording

Recording starts after the save location and permissions are confirmed, followed by a three-second countdown. Pause and resume are supported; paused time is excluded from the video. A border and a light mask outside the recording area remain during the countdown and recording, allow pointer input to pass through, and are excluded from the video along with the control window.

Hiding the control window keeps recording; use Show Controls in the menu to restore it. Closing the control window stops and saves the recording, and the window stays closed after a successful save. You can stop recording with macOS's recording control in the menu bar. The Patch menu also offers stop, pause, and resume. Segments are merged into one MP4 after pausing; original segments remain until saving succeeds. If saving fails, the control window reappears so you can retry.

## Permissions, scrolling captures, and background operation

- Grant screen capture, microphone, and accessibility / device control permissions as needed. Restart Patch if a granted permission has not taken effect.
- Scrolling captures preserve the full confirmed selection. By default, hover to identify a window and click to select it, or drag to select a region. `R` selects a free region; `W` selects a window. You can also start a scrolling capture from a regular screenshot's toolbar, reusing the region with a fresh capture. Existing annotations require confirmation before being cleared; canceling keeps the original screenshot.
- Stitching uses real captured pixels with hard seams, without blending pixels or inventing obscured content. Fixed headers and overlays may remain or repeat. A frame that cannot be reliably positioned is skipped while sampling continues. Automatic mode switches to manual mode; you can keep scrolling, finish, or annotate the existing result. Dynamic layouts and multiple scrollable containers may not stitch reliably. Reselect lets you change the region: confirming starts a new capture; Esc retains the old result and returns to the paused state.
- Opening settings, history, annotation, or other feature windows shows the Dock icon. Closing all feature windows returns Patch to menu-bar-only operation. Minimized windows keep the Dock entry. Only Quit ends the app; pins last for the current session only.
