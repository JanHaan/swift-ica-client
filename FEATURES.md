# Feature matrix: stock Citrix Workspace app vs ICAViewer

ICAViewer is an independent project and is not affiliated with Citrix. The stock-client columns
summarise Citrix's public documentation (links under Sources); the ICAViewer column describes this
client.

Status date: 2026-11-07, v0.4.0 (ICAViewer column); stock columns from Citrix documentation as fetched
2026-11-05.

## How to read this

- Stock columns come mainly from the official **Citrix Workspace app feature matrix** (page dated
  2026-10-30; Windows = Current Release column, 2603.x; the LTSR column was identical for almost every
  row used here). Newer facts come from the per-platform "What's new" pages: Mac up to 2609, Linux 2608,
  HTML5 2607, iOS 26.9, Android 26.7. The Windows and ChromeOS "What's new" pages could not be read,
  so their columns rest on the matrix alone.
- Cell values: ✅ supported, ⚠️ partial (see footnote), ❌ not supported, ? not verified.
- **†** = the cited pages do not state it; the value comes from general product knowledge and is
  unverified. Treat it as "probably". Cells without † that show ✅/❌ are on a cited page.
- Some "yes" cells in the matrix hide platform caveats (for example Mac "Multi-port ICA: No",
  Windows "Remote access via Gateway: StoreFront only"). The matrix says nothing about quality or
  depth of a feature, so a ✅ means "listed as supported", not "works as well as on Windows".
- The pages were read through a summarising fetch tool, not by hand. Spot-check any cell before
  relying on it for a decision.

## Matrix

Columns: Win = Windows, Mac = macOS, Lin = Linux, Web = HTML5 (browser), ChrOS = ChromeOS,
**Ours** = ICAViewer v0.4.0, 2026-11-07.

| Feature | Win | Mac | Lin | Web | ChrOS | iOS | Andr | **Ours** |
|---|---|---|---|---|---|---|---|---|
| **Access & auth** | | | | | | | | |
| StoreFront via NetScaler Gateway | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ [1] |
| StoreFront direct (intranet) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ [2] |
| Citrix Cloud / Workspace | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| NetScaler nFactor / MFA | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ [3] |
| Smart card authentication | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ | ✅ | ❌ |
| SSO / pass-through authentication | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ [4] |
| FIDO2 / passkeys | ✅† | ✅ | ✅ | ? | ? | ✅ | ✅ | ❌ |
| **Session launch** | | | | | | | | |
| Seamless published apps | ✅† | ⚠️ [5] | ? | ⚠️ [6] | ? | ⚠️† [7] | ⚠️† [7] | ✅ [8] |
| Full desktops | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ? [9] |
| Session sharing (several apps, one session) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ [45] |
| Reconnect to disconnected session / Follow Me | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ [10] |
| Connection Center / session management | ✅† | ? | ? | ? | ? | ? | ? | ⚠️ [11] |
| **Transport** | | | | | | | | |
| TLS via Gateway | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Session reliability | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ [12] |
| Auto client reconnect | ✅ | ✅ | ✅ | ⚠️ [13] | ✅ | ❌ | ✅ | ❌ (planned) |
| EDT / UDP (adaptive transport) | ✅ | ✅ | ✅ | ⚠️ [14] | ✅ | ✅ | ✅ | ❌ |
| Rendezvous / HDX Direct | ? | ⚠️ [15] | ⚠️ [15] | ? | ? | ? | ? | ❌ |
| **Graphics** | | | | | | | | |
| Thinwire classic | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| H.264 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ [16] |
| H.265 / AV1 | ✅ | ⚠️ [17] | ⚠️ [17] | ? | ? | ? | ? | ❌ |
| YUV444 (4:4:4) | ✅ | ✅ | ? | ? | ? | ? | ? | ❌ |
| True multi-monitor | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ [18] | ⚠️ [18] | ✅ [19] |
| DPI scaling / HiDPI | ✅† | ? | ? | ✅ | ? | ✅ | ✅ | ✅ [20] |
| Adaptive display / throughput | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ✅ [21] |
| **Seamless integration** | | | | | | | | |
| Native per-window integration | ✅† | ⚠️ [5] | ? | ❌ [6] | ? | ❌† | ❌† | ✅ [22] |
| Taskbar / Dock entry per remote app | ✅† | ⚠️ [5] | ? | ❌ | ? | ❌† | ❌† | ✅ [23] |
| Visible to window switchers | ✅† | ⚠️ [5] | ? | ❌ | ? | ❌† | ❌† | ✅ [22] |
| App icons | ✅† | ✅ | ? | ? | ? | ? | ? | ✅ [24] |
| **Input** | | | | | | | | |
| Keyboard layout sync (client to Windows VDA) | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ [25] |
| Scancode keyboard mode | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| Unicode keyboard mode | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ [26] |
| IME (CJK) | ✅ | ✅ | ⚠️ [27] | ✅ | ✅ | ✅ | ✅ | ❌ |
| Mouse and wheel | ✅† | ✅† | ✅† | ✅† | ✅† | ✅† | ✅† | ✅ |
| Relative mouse | ? | ? | ? | ? | ? | ? | ? | ? [28] |
| Touch / pen | ✅ [29] | ❌ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **Devices & redirection** | | | | | | | | |
| Clipboard (text / image / files) | ✅† | ✅ | ✅ | ⚠️ [30] | ? | ? | ? | ⚠️ [31] |
| Client drive mapping / file transfer | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ [32] |
| Printing (client printers) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ⚠️ [41] |
| Generic USB | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Smart card into session | ✅† | ? | ✅ | ? | ? | ? | ? | ❌ |
| Scanners / TWAIN | ✅ | ❌ | ⚠️ [33] | ❌ | ❌ | ❌ | ❌ | ❌ |
| Webcam | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️ [43] |
| Audio out | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ [42] |
| Microphone (bidirectional audio) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ [44] |
| MS Teams optimisation | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ [34] |
| Zoom / WebEx optimisation | ✅† | ? | ? | ? | ? | ? | ? | ❌ |
| Browser content redirection | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ |
| Windows multimedia redirection | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Location services | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| **Security** | | | | | | | | |
| Secure ICA / Secure HDX encryption | ✅† | ? | ✅ | ✅† | ✅† | ✅ | ✅ | ❌ [35] |
| App Protection | ✅ | ✅ | ✅ [36] | ❌ | ❌ | ✅ | ✅ | ❌ |
| Endpoint analysis (EPA) | ✅† | ? | ✅ | ? | ? | ? | ? | ❌ [37] |
| **Management** | | | | | | | | |
| Config via policy / GACS | ✅ | ✅ | ⚠️ [38] | ✅ | ✅ | ✅ | ✅ | ❌ |
| Auto-update | ✅ | ✅ | ❌ | ❌ | ❌ | ⚠️ [39] | ⚠️ [39] | ❌ |
| Telemetry / experience metrics | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ [40] |
| In-app problem report | ? | ? | ? | ? | ? | ? | ? | ✅ [46] |

## Footnotes

1. nFactor ExplicitForms (username, password, TOTP), StoreFront Receiver-for-Web API,
   CitrixAGBasic SSO. Verified live.
2. Designed but not tested; all testing so far ran through the gateway.
3. ICAViewer implements only the ExplicitForms factor with a TOTP passcode. Other nFactor schemas
   (SAML, certificate, push) are not implemented. NetScaler accepts each TOTP code once.
4. Entra ID SSO exists in some clients (Linux 2604, HTML5 2511, iOS 25.11, Android 25.11) but is a
   different feature; it is not counted here.
5. Observed on the stock Mac client (Citrix Viewer 26.09) through macOS Accessibility: seamless
   windows are borderless, reported as `AXDialog` with no title-bar buttons; Dock icons come from
   per-window "Husk" processes that own no windows.
6. HTML5 runs inside a browser tab, so remote apps are not separate OS windows.
7. Mobile clients show published apps inside a session view, not as OS windows. Unverified.
8. Tested live with a calculator and a mail client.
9. Not tested. The seamless path is the only one exercised.
10. Launching a resource reconnects to the existing session, and the launcher offers to reconnect
    disconnected sessions at start. Verified live.
11. A Connection Center window lists sessions and can reconnect, disconnect or log off through the
    store's session endpoints; Cmd-Q asks Disconnect (default) or Log off. Verified live with a
    user. The launcher also offers to reconnect disconnected sessions at start (verified live).
12. Resumes after a network drop, a Wi-Fi change or a short sleep, as long as the outage stays within
    the server's reliability timeout (typically 180 s). Verified live. On longer outages a Reconnect
    panel relaunches the app, which reconnects to the disconnected session.
13. Conflict: the feature matrix says "No"; the HTML5 2607 notes list Auto Client Reconnect as new.
    Treat as partial.
14. Conflict: the matrix says adaptive transport is "No" for HTML5, but the 2603 notes mention "EDT
    Reliable". Treat as partial.
15. Mac 2503/2609 and Linux 2608 list HDX Direct (direct VDA connection without a gateway). Rendezvous
    itself is not stated on any page read.
16. VideoToolbox decoder implemented; not tested live because the tested server policy selects
    classic Thinwire.
17. Mac notes mention an H.265 (HEVC) hardware-acceleration switch; Linux notes list H.264/H.265
    hardware decoding. AV1 is not confirmed for either. Windows negotiates AV1, then H.265, then H.264
    per Citrix's Thinwire documentation.
18. Matrix: "External monitor support" yes, "True multi-monitor" no.
19. The session desktop is the union of all screens; its size stays fixed for the session even if
    screens change.
20. Windows scaling and client scaling are separate settings. Auto (default) is Retina-sharp at normal
    size: per screen, 2x with a 200 % Windows DPI on Retina, 1x otherwise. It falls back to 1x when
    the session would exceed the protocol's size limit (5120x4096). Verified live on a single Retina
    screen (pixel-exact 2x, mouse mapping correct) and on two Retina screens, which would exceed the
    limit and fall back to 1x; Settings explains the fallback. A settings change mid-session offers
    a reconnect.
21. ICAViewer uses a client-side frame-rate governor (5 fps idle, 30 fps active), not Citrix's HDX
    adaptive throughput. Idle host repaints (about 154 kB/s for a mail client) still arrive.
22. Each remote window is a real `NSWindow`: `AXStandardWindow`, working minimize, no duplicate title
    bar, visible to Cmd-Tab and third-party window switchers.
23. Since 0.5: one Dock and Cmd-Tab entry per remote app, with its own name, icon and Mac menu bar,
    through a small helper app per remote app that shows that app's windows.
    ICA Viewer itself moves to the menu bar while remote apps are open; ⌃⌥⌘L opens the launcher.
    On by default; Settings switches back to one Dock entry. Verified live.
24. The launcher shows the real app icons, and the Dock and Cmd-Tab icon follows the active remote app
    (icons from the store, else the session). Verified live.
25. Scancodes with a German layout. There is no dynamic layout sync from the Mac to the VDA.
26. Unicode events exist only for Option-composed characters; scancodes cover the rest.
27. Matrix: server IME yes, generic client IME (CTXIME) no.
28. Not yet investigated. Unverified for stock clients too.
29. Windows is listed as multi-touch yes; pen is not covered on any page read.
30. Clipboard text/HTML is confirmed for HTML5 (2607 fix notes); files and images are unverified.
31. Text works both ways (verified live). HTML, RTF and images are implemented but not yet verified
    live. Files are not supported yet: the host offers `FileGroupDescriptorW` / `FileContents`, which
    remains to be investigated.
32. One shared folder (default `~/Citrix Shared`, read-write, strict confinement, quarantine flag on
    files written by the session) is exposed as a client drive. Implemented and security-reviewed,
    but not verified live: the test site does not redirect client drives. No general file transfer.
33. Linux lists SANE scanner optimisation (2604) but no TWAIN.
34. Not currently planned.
35. Not needed: the transport is TLS to the gateway. Basic encryption was never started by the server
    in testing.
36. As listed in the matrix. The Linux cell is surprising; verify before relying on it.
37. Not needed with the tested gateway policy, which has no EPA step. Linux 2601 added EPA plug-in
    handling.
38. Linux has centralised management settings but no Global App Config.
39. Updates via the App Store or Play Store, not the Citrix auto-update service.
40. None, by design.
41. PDF printing through the host's PDF printer to the macOS print panel; nothing prints without a
    click. Implemented, off by default, not verified live: the test site creates no client printers.
42. Playback (PCM, Opus) verified live: the sound was heard on the Mac.
43. HDX webcam redirection (H.264) with a camera picker. Off by default; the camera opens only while
    the host is using it, and a menu-bar item disables it for the session. The host handshake is
    verified live (headless, with a synthetic test pattern) and the picker lists the cameras, but a
    real camera has not been tried. This client path supports 32-bit host applications only; 64-bit
    apps (Windows Camera, Teams, modern browsers) will not see the camera. Teams optimisation is
    separate.
44. Opus uplink, sent when a session application records. Off by default in Settings; macOS asks for
    permission on first use, and a menu-bar item disables the microphone for the current session.
    Verified live. The row is for audio only; Teams optimisation is separate.
45. Several published apps run in one session: the second app is launched into the running session
    over the control channel, with no second logon. Verified live (a second app started fast, the
    Dock icon and menu name followed, closing one app left the other running). Logoff happens only
    when all apps have ended.
46. Help > Report a Problem... builds a scrubbed report with a preview and a prefilled GitHub issue
    plus a saved report file. You review the report before anything is shared; nothing is sent
    automatically. Verified live (dialog and preview).

## Gaps that matter most

Ordered for daily use through a gateway with mail and line-of-business applications.

1. **Auto client reconnect.** Session reliability now covers short outages; automatic reconnect
   after longer ones is still manual (the Reconnect panel).
2. **Live verification of what is already built.** Client drive mapping and printing are
   implemented but need a site that redirects drives and printers; clipboard HTML, RTF and images
   are unverified too, as is the webcam with a real camera.
3. **Real-camera check of the webcam.** Implemented; only 32-bit host apps can use it (Teams
   optimisation is a separate, larger piece).
4. **Full-desktop launch.** Only seamless apps are exercised.
5. **General file transfer and clipboard files.** Only the shared folder exists.
6. **EDT/UDP and further authentication methods** beyond ExplicitForms with TOTP; H.264 is untested.

Not listed because they matter only in particular deployments: smart card, FIDO2, pass-through,
Citrix Cloud, App Protection, EPA, GACS, auto-update.

## Where ICAViewer exceeds stock

**Native window integration on macOS.** In the stock Mac client (Citrix Viewer 26.09), seamless
windows are borderless windows that Accessibility reports as `AXDialog` without title-bar buttons.
Some third-party window switchers require a standard window with a minimize button and therefore
skip them. The Dock icons come from placeholder "Husk" processes (`com.citrix.ctxapphusk`) that own
no windows, controlled by `enableAppDockEnhancement` / `EnableAppPreview`. In ICAViewer each remote
window is an `AXStandardWindow` with an enabled minimize button that round-trips to a TWI minimise,
a single caption (the remote one). Verified across two screens. Since 0.5 each remote app also has
its own Dock and Cmd-Tab entry, with its name, icon and menu bar.

Secondary points: no telemetry, no background services, and the whole client is small enough to
read in one sitting. These are design choices rather than features, and they come at the price of
every row above that is marked ❌.

## Sources

Stock-client documentation (fetched 2026-11-05):

- Feature matrix, dated 2026-10-30: https://docs.citrix.com/en-us/citrix-workspace-app/citrix-workspace-app-feature-matrix.html
- Mac, What's new (2409 to 2609): https://docs.citrix.com/en-us/citrix-workspace-app-for-mac/whats-new.html
- Mac 2603 release page: https://www.citrix.com/downloads/workspace-app/mac/workspace-app-for-mac-latest2603.html
- Linux, What's new (2601 to 2608): https://docs.citrix.com/en-us/citrix-workspace-app-for-linux/whats-new.html
- HTML5, What's new (2408 to 2607): https://docs.citrix.com/en-us/citrix-workspace-app-for-html5/whats-new.html
- iOS, What's new (25.9 to 26.9): https://docs.citrix.com/en-us/citrix-workspace-app-for-ios/whats-new.html
- Android, What's new (25.7 to 26.7): https://docs.citrix.com/en-us/citrix-workspace-app-for-android/whats-new.html
- Windows, About this release (known only from search snippets): https://docs.citrix.com/en-us/citrix-workspace-app-for-windows/whats-new
- Windows 2603.11 PDF (not opened): https://docs.citrix.com/en-us/citrix-workspace-app-for-windows/downloads/citrix_workspace_app_2603_11_for_windows.pdf
- Thinwire / codec negotiation (H.264, H.265, AV1, 4:4:4): https://docs.citrix.com/en-us/citrix-virtual-apps-desktops/2311/graphics/thinwire.html
- ChromeOS: no readable page; the column is the feature matrix only.
