# Patch privacy notice

[简体中文](privacy-policy.md) · [English](privacy-policy.en.md)

Updated: November 13, 2026. This notice describes Patch 0.1.5. The maintainer is caijyii, reachable at [caijyii@163.com](mailto:caijyii@163.com).

## Local processing

Patch is a macOS tool for screenshots, annotations, desktop pins, scrolling captures, text recognition, and screen recording. The app has no accounts, ads, analytics SDKs, or network features that upload your content. Screenshots, text recognition, subject extraction, and annotations use local system frameworks. Patch does not send screen content, recognized text, or audio recordings to the developer.

## Permissions by feature

- Screen and system audio recording: used for screenshots, scrolling captures, or recordings you start. System audio is controlled by the recording options.
- Microphone: used only when you enable microphone recording.
- Device control / accessibility: used for automatic scrolling and horizontal scroll filtering in scrolling captures. Clipboard history does not use this access to locate external inputs or send paste commands.
- User-selected file access: used to save output to a location you choose through the system save dialog.

You can revoke permissions in macOS System Settings; the corresponding features will then be unavailable. Permission names may vary by macOS version.

## Clipboard, files, and preferences

Patch reads the current clipboard at startup and checks for changes while running. It adds images, plain and basic rich text, and video files copied in Finder to clipboard history, along with screenshots completed through Patch, copied recognized text, pins, and successfully saved recordings. Automatic collection is always on while Patch is running and has no toggle. It skips clipboard content marked by the source app as concealed, transient, or automatically generated, but cannot detect all sensitive content.

Clipboard history is held only in the current process's memory. It is not written to disk or uploaded and is cleared when Patch quits. You can delete one record or clear the selected category; selecting All clears every category. Text is limited to 100 items / 8 MiB, images to 20 items / 128 MiB (including decoded image size, PNG data, and thumbnails), and video references and thumbnails to 5 items / 8 MiB. Each category independently evicts its oldest records. Oversized individual items are not collected.

Video history retains only original file references and thumbnails, not complete video copies. Patch recordings are saved separately to a location you choose. Deleting or clearing video records does not delete the original files; moving, deleting, or losing access to a file may invalidate its record. Closing the home window does not quit Patch; it continues running in the menu bar.

Copying places output on the system clipboard. Clearing Patch history does not clear the system clipboard. macOS controls the system clipboard and its system-level synchronization. Copying a video writes its original file reference to the clipboard; whether it can be pasted depends on the receiving app.

Images, text, and annotations are kept in memory during the session. Exported images and videos remain where you save them. Recording uses temporary files accessible to the app and attempts to remove them after a successful export; failed saves may leave temporary recordings for recovery. Uninstalling Patch does not automatically delete exported files.

Shortcuts, annotation preferences, sticker order, appearance, interface language, batch pin count, and screenshot / recording pin-hiding options are stored in local app preferences. History content is not included in those preferences. Interface translations are bundled with the app; clipboard content is not uploaded for translation. System logs may contain error codes, image dimensions, processing durations, and diagnostic metadata for scrolling events. Patch has no feature that automatically sends logs to the developer.

## Feedback and third-party services

If you choose to submit descriptions, images, or logs through a repository or support channel, those materials are handled by the platform you select. Do not include sensitive content in public reports. Apple handles App Store downloads, payments, and system diagnostics under its own rules.
