# 16. Privacy and security

This chapter says what ICA Viewer stores and what leaves your Mac.

## What leaves your Mac

- **The connection to your organization's server.** ICA Viewer connects only to the gateway or store address you give it, and from there to the session. The connection is encrypted with TLS. ICA Viewer has no server of its own and sends no data to its authors or to anyone else.
- **Your sign-in.** Your user name, password and one-time code go to your organization's gateway or store, as with any Citrix client.
- **What you choose to share.** The clipboard, files you copy, a shared folder, the microphone or the camera reach the session only when you turn these on or use them (see below). The microphone and the camera are on by default, but they are used only while a remote app records or uses the camera, and only after you allowed it when macOS asked.
- **Reports.** A problem report is sent only when you create a GitHub issue yourself, after you have read the preview ([Report a Problem](13-report-a-problem.md)).

ICA Viewer does not check for updates and does not collect usage data.

## What is stored on your Mac

| What | Where | Notes |
|---|---|---|
| Your password and TOTP secret | Keychain, this Mac only | Only if you tick **Remember in Keychain**. Never in iCloud. Touch ID or your Mac password can be required to read them |
| Settings | `~/Library/Preferences/local.alttab.ICAViewer.plist` | No secrets |
| Log | `~/Library/Logs/ICAViewer` | Readable only by you; not scrubbed; may contain host and app names |
| Files copied from the session | A temporary folder in `~/Library/Caches/ICAViewer`, removed at the next copy and when you quit | The files you paste stay where Finder puts them |
| The shared folder | `~/Citrix Shared` (or the one you choose) | Only if you turn on the client drive |

**Forget All Saved Credentials** in **Settings > Account** deletes the password and TOTP secret, and also signs out at the server.

## What a remote app can do on your Mac

- It **cannot** see your Mac's files, unless you share a folder or copy files into the session.
- It **can read and change everything in the shared folder** while the client drive is on. Use a folder just for this, or **Read-only**.
- It can read the **clipboard** when you copy or paste with the session: do not copy secrets you do not want a remote app to see.
- It can use the **microphone** only while it records and you allowed it in macOS (you can turn it off in **Settings**), and the **camera** only while it uses it and you allowed it in macOS (you can turn it off in **Settings**). The menu bar shows when they are in use, and you can switch them off for the current session.
- Files from the session carry the macOS **quarantine flag**, so macOS checks them before opening.

## Permissions macOS may ask for

| Permission | When |
|---|---|
| Microphone | A remote app records for the first time (**Pass the microphone to the session** is on by default) |
| Camera | A remote app uses the camera for the first time (**Pass the camera to the session** is on by default) |
| Files and Folders | You share a folder or copy files |
| Touch ID | Reading a protected saved password or TOTP secret |

ICA Viewer does not need Screen Recording, Accessibility or Full Disk Access.

## About the project

ICA Viewer is an independent, open-source project, licensed under the MIT or Apache-2.0 license, at your option. It contains no code from Citrix. It is not affiliated with Citrix and carries no support from Citrix or from your organization's IT department. Ask your IT department whether you may use it with your company's servers.
