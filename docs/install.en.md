# Install Patch

[简体中文](install.md) · [English](install.en.md)

Requires **Apple Silicon (M-series chips) and macOS 15 or later**. Xcode and Command Line Tools are not required. Intel installers are not currently available.

## Download and install

1. Download the [latest stable release](https://github.com/caijyii/patch/releases/latest), currently **v0.1.2**. **DMG is recommended**: `Patch-0.1.2-macOS-arm64.dmg`. ZIP is an alternative installation method; choose just one. `Source code` contains source files, not an installer for ordinary users. If the maintainer provided a DMG directly, start with step 2.
2. **DMG**: Open it and drag `Patch.app` into the adjacent Applications folder, then eject the disk image. **ZIP**: Extract it and move `Patch.app` into Applications. Quit other Patch versions first and confirm any replacement of an existing installation.
3. Open Patch from Applications and grant permissions for the features you use.

This release is ad-hoc signed. **It does not have a Developer ID signature and has not been notarized by Apple.** If macOS cannot verify the developer, confirm the source and file integrity, then follow [Apple's instructions](https://support.apple.com/102445) to check for an Open Anyway option in System Settings → Privacy & Security. If macOS reports malware or a damaged file, stop and report the issue. Do not disable Gatekeeper or bypass those warnings.

Screen capture permission is required for screenshots and recordings. Microphone and scrolling control permissions are requested as needed. Complete system verification and permission prompts yourself. Updating an ad-hoc signed build may require granting permissions again. Use one installed copy of Patch at a time.

## Ask an agent to install

You can give your agent this instruction:

> Download the Patch installer compatible with my Mac from the GitHub Releases at https://github.com/caijyii/patch and install it.

<details>
<summary>Installation details for agents</summary>

1. Read release information from GitHub Releases or `https://api.github.com/repos/caijyii/patch/releases`. Preview releases may not appear in `/releases/latest`; check `draft`, `prerelease`, version, and publication date.
2. Download only attachments from the selected release. Check the manifest for the operating system, architecture, filenames, signing status, and download URLs. This release requires `arm64` and `macOS 15+`.
3. Compare the selected DMG or ZIP's SHA-256 with the same release's checksum file and manifest. The DMG added later to `v0.1.0-preview.1` has separate `SHA256SUMS-DMG.txt` and `dmg-manifest.json` files; its original ZIP uses `SHA256SUMS.txt` and `release-manifest.json`. Checksums verify file consistency; they do not replace Developer ID signing or establish a trusted source.
4. Extract ZIPs into a temporary directory. Mount DMGs read-only and eject them afterward. Confirm the expected `Patch.app` bundle; the DMG also contains an Applications shortcut. Verify the `dev.screenleaf.app` identifier, version, arm64 architecture, and `codesign --verify --deep --strict`. Passing ad-hoc signature verification does not mean the app is notarized.
5. Install into `/Applications` or the user's chosen `~/Applications`. If Patch or an app with the same name already exists or is running, confirm what will be replaced and keep a recoverable old copy. Do not automatically end a capture or recording session.
6. Preserve download quarantine attributes and follow system prompts on first launch. Do not automatically grant privacy permissions or ask the user to provide their password to an agent.

</details>

## Verify a download

Run this in the download directory, using the filename for the selected release:

```sh
shasum -a 256 Patch-0.1.2-macOS-arm64.zip
```

Compare the result with `SHA256SUMS.txt` from the same release. For a DMG, use `shasum -a 256 filename.dmg`. Both current installer formats are listed in `SHA256SUMS.txt`; only the DMG added later to `v0.1.0-preview.1` uses a separate `SHA256SUMS-DMG.txt`. You only need to download your preferred format.

## Update or uninstall

Updates require manually downloading an installer; Patch does not automatically check for or install updates. Visit the [latest stable release](https://github.com/caijyii/patch/releases/latest), compare versions, read the release notes, and download the new DMG (or ZIP). Use the steps below to replace earlier preview installations too. In-place upgrade testing on a real system remains outstanding; this is not a validation claim for every older version.

1. Save any pins you want to keep and finish any capture or recording, then choose Quit from the Patch menu bar menu. Quitting closes pins and clears the current clipboard history; closing the home window alone does not quit.
2. Open the new DMG (or extract the ZIP) and drag `Patch.app` into Applications. Choose Replace if an older copy exists, keeping the same installation location.
3. Eject the disk image if you used a DMG, then open Patch from Applications. If screen capture or recording permissions are requested again, grant them and restart Patch.
4. Shortcuts, appearance, language, and sticker order are retained under the same app identifier. An unchanged set of old default shortcuts migrates to the new order; custom shortcuts are preserved.

If an older copy is in Downloads or another folder, quit it and move that copy to Trash. Launch the installed copy from Applications. Patch Development uses a separate identifier, preferences, and permissions; you can remove old development copies after quitting them.

To uninstall, quit Patch and move `Patch.app` to Trash. Exported screenshots and recordings remain where you saved them. Keep the app's preferences and container files when upgrading in place.
