# 1. Installation

## What you need

- A Mac with macOS 14 (Sonoma) or later. Apple silicon and Intel Macs are both supported.
- The address of your organization's Citrix gateway or StoreFront store, and your account.

## Install the app

1. Download the disk image `swift-ica-client-<version>.dmg` from the project's **Releases** page on GitHub. The release notes list its SHA-256 checksum; to check your download, open Terminal and run `shasum -a 256` on the file.
2. Double-click the disk image. A window opens with **ICAViewer** and a shortcut to **Applications**.
3. Drag **ICAViewer** onto **Applications**.

![The disk image window: drag ICAViewer onto Applications](images/dmg.png)

4. Eject the disk image (drag it to the Trash, or press the eject button next to it in the Finder sidebar).

## First start

Open **ICAViewer** from **Applications** (or with Spotlight).

The app is signed with a Developer ID and notarized by Apple, so it opens like any other app downloaded from the internet. macOS may show one confirmation that the app was downloaded from the internet; click **Open**.

On the first start ICA Viewer shows the **Sign In** window ([Signing in](02-signing-in.md)). Nothing is read from your Mac, and no folder or device is shared, until you sign in and start an app. macOS asks for permission the first time a feature needs it:

- **Microphone**, the first time a remote app records ([Audio, microphone and webcam](08-audio-video.md)).
- **Camera**, only if you turn it on in **Settings** and a remote app uses it.
- **Files and Folders**, when you share a folder or copy files.

> **If macOS refuses to open the app.** A build that is not notarized (for example one you built yourself) is blocked on its first start. Open **System Settings > Privacy & Security**, scroll down and click **Open Anyway** for ICAViewer. Alternatively, run `xattr -dr com.apple.quarantine /Applications/ICAViewer.app` in Terminal.

## Update

Download the new disk image and drag **ICAViewer** to **Applications** again, replacing the old one. Quit ICA Viewer first. Your settings and saved logins stay.

ICA Viewer does not check for updates by itself. Look at the Releases page now and then.

## Remove

1. Quit ICA Viewer.
2. Drag **ICAViewer** from **Applications** to the Trash.
3. Optional: remove what it leaves behind.
   - Saved logins: open ICA Viewer first and use **Forget All Saved Credentials** in **Settings** ([Settings](12-settings.md)), or delete the entries for your store in **Keychain Access**.
   - Settings: `~/Library/Preferences/local.alttab.ICAViewer.plist`.
   - Logs: `~/Library/Logs/ICAViewer`.
   - The shared folder `~/Citrix Shared`, if you used it ([Client drives](06-drives.md)).
