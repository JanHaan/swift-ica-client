# 6. Client drives

A **client drive** shows one folder of your Mac as a drive inside the remote session, so a Windows app can open and save files there directly.

## How it works

- ICA Viewer shares exactly one folder. The default is **Citrix Shared** in your home folder; it is created the first time it is used.
- In Windows the folder appears as drive **M** (named after your Mac).
- The session can read and change everything in that folder, and nothing outside it. Use a dedicated folder rather than your Documents.
- Files that the session writes into the folder carry the macOS quarantine flag, so macOS checks them before opening them.

## Settings

Open **Settings > Devices** ([Settings](12-settings.md#client-drive)):

- **Share a folder with sessions as drive M** turns the feature on or off.
- **Choose…** picks another folder, and **Show in Finder** opens the current one.
- **Read-only (the session cannot change files)** lets Windows read but not write.

The change applies from the next time you connect.

## If you do not see the drive

The server decides whether client drives are allowed. If your organization blocks them, the [Connection Center](10-connection-center.md#features-the-server-refuses) shows "Client drives: blocked by server policy". The lab server used for this manual does not provide client drives, so there is no screenshot of drive M in File Explorer.
