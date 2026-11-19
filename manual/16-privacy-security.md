# 16. Privacy and security

This chapter says what ICA Viewer stores and what leaves your Mac.

## What leaves your Mac

- **The connection to your organization's server.** ICA Viewer connects only to the gateway or store address you give it, and from there to the session. Through a gateway, sessions are always encrypted with TLS. A store you reach directly decides this itself: if a session is not encrypted, the Connection Center shows **Connection: not encrypted**. A store address that starts with `http://` is not encrypted at all, your password included. ICA Viewer has no server of its own and sends no data to its authors or to anyone else.
- **Your sign-in.** Your user name, password and one-time code go to your organization's gateway or store, as with any Citrix client.
- **What you choose to share.** The clipboard, files you copy, a shared folder, the microphone or the camera reach the session only when you turn these on or use them (see below). The microphone and the camera are on by default, but they are used only while a remote app records or uses the camera, and only after you allowed it when macOS asked. macOS asks once: after that, any remote app in any session can use them without asking again, and the menu bar shows when it does.
- **Reports.** A problem report is sent only when you create a GitHub issue yourself, after you have read the preview ([Report a Problem](13-report-a-problem.md)).

ICA Viewer does not check for updates and does not collect usage data.

## What is stored on your Mac

| What | Where | Notes |
|---|---|---|
| Your password and TOTP secret | Keychain, this Mac only | Only if you tick **Remember in Keychain**. Never in iCloud. Touch ID or your Mac password can be required to read them |
| Settings | `~/Library/Preferences/local.alttab.ICAViewer.plist` | No secrets |
| Sign-in cookies, which Dock name belongs to which app, the Dock apps | `~/Library/Application Support/ICAViewer` | Readable only by you. The cookies keep you signed in; **Sign Out** and **Forget All Saved Credentials** delete them |
| App icons from the store | `~/Library/Caches/ICAViewer` | |
| Log | `~/Library/Logs/ICAViewer` | Readable only by you; not scrubbed; may contain host and app names |
| Files copied from the session | A temporary folder in `~/Library/Caches/ICAViewer`, removed at the next copy and when you quit | The files you paste stay where Finder puts them |
| The shared folder | `~/Citrix Shared` (or the one you choose) | Only if you turn on the client drive |

**Forget All Saved Credentials** in **Settings > Account** deletes the password and TOTP secret, and also signs out at the server.

## What a remote app can do on your Mac

- It **cannot** see your Mac's files, unless you share a folder or copy files into the session.
- It **can read and change everything in the shared folder** while the client drive is on. Use a folder just for this, or **Read-only**.
- It can read the **clipboard** when you copy or paste with the session: do not copy secrets you do not want a remote app to see.
- It can use the **microphone** only while it records and you allowed it in macOS (you can turn it off in **Settings**), and the **camera** only while it uses it and you allowed it in macOS (you can turn it off in **Settings**). The menu bar shows when they are in use, and you can switch them off for the current session. If a remote app ends while it uses the camera, Windows does not always tell ICA Viewer, and the camera can stay on until another app uses it or you switch it off in the menu bar.
- Files from the session carry the macOS **quarantine flag**, so macOS checks them before opening.
- If the server hands links over, it **can open web pages in your default browser** (at most five in 30 seconds), including pages on your home or office network. It cannot open files, mail links or other programs on your Mac this way.

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
