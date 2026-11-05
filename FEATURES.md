# Feature matrix: stock Citrix Workspace app vs ICAViewer

ICAViewer is an independent project and is not affiliated with Citrix. The stock-client columns
summarise Citrix's public documentation (links under Sources); the ICAViewer column describes this
client.

Status date: 2026-11-05 (ICAViewer column); stock columns from Citrix documentation as fetched
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
**Ours** = ICAViewer, 2026-11-05.

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
| Session sharing (several apps, one session) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Reconnect to disconnected session / Follow Me | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ [10] |
| Connection Center / session management | ✅† | ? | ? | ? | ? | ? | ? | ❌ [11] |
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
| DPI scaling / HiDPI | ✅† | ? | ? | ✅ | ? | ✅ | ✅ | ⚠️ [20] |
| Adaptive display / throughput | ✅ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ✅ [21] |
| **Seamless integration** | | | | | | | | |
| Native per-window integration | ✅† | ⚠️ [5] | ? | ❌ [6] | ? | ❌† | ❌† | ✅ [22] |
| Taskbar / Dock entry per remote app | ✅† | ⚠️ [5] | ? | ❌ | ? | ❌† | ❌† | ❌ [23] |
| Visible to window switchers | ✅† | ⚠️ [5] | ? | ❌ | ? | ❌† | ❌† | ✅ [22] |
| App icons | ✅† | ✅ | ? | ? | ? | ? | ? | ⚠️ [24] |
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
| Client drive mapping / file transfer | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ [32] |
| Printing (client printers) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| Generic USB | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| Smart card into session | ✅† | ? | ✅ | ? | ? | ? | ? | ❌ |
| Scanners / TWAIN | ✅ | ❌ | ⚠️ [33] | ❌ | ❌ | ❌ | ❌ | ❌ |
| Webcam | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ [32] |
| Audio out | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ [32] |
| Microphone (bidirectional audio) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ [32] |
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
10. Implicit: launching a resource reconnects to the existing session. Verified live.
11. Planned: the `Sessions/List`, `Disconnect` and `Logoff` store endpoints.
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
20. One session pixel is one point; no Retina resolution. A 200 % DPI request made the host render 2x.
21. ICAViewer uses a client-side frame-rate governor (5 fps idle, 30 fps active), not Citrix's HDX
    adaptive throughput. Idle host repaints (about 154 kB/s for a mail client) still arrive.
22. Each remote window is a real `NSWindow`: `AXStandardWindow`, working minimize, no duplicate title
    bar, visible to Cmd-Tab and third-party window switchers.
23. Planned: one Cmd-Tab/Dock identity per remote app, probably via generated helper bundles. Today
    the whole client is one Dock entry.
24. Icons are decoded from the TWI channel but not yet shown in any UI.
25. Scancodes with a German layout. There is no dynamic layout sync from the Mac to the VDA.
26. Unicode events exist only for Option-composed characters; scancodes cover the rest.
27. Matrix: server IME yes, generic client IME (CTXIME) no.
28. Not yet investigated. Unverified for stock clients too.
29. Windows is listed as multi-touch yes; pen is not covered on any page read.
30. Clipboard text/HTML is confirmed for HTML5 (2607 fix notes); files and images are unverified.
31. Text works both ways (verified live). HTML, RTF and images are implemented but not yet verified
    live. Files are not supported yet: the host offers `FileGroupDescriptorW` / `FileContents`, which
    remains to be investigated.
32. Planned: client drive mapping (`CTXCDM`) or `CTXFILE`, then audio out, microphone and webcam.
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

## Gaps that matter most

Ordered for daily use through a gateway with mail and line-of-business applications.

1. **Auto client reconnect.** Session reliability now covers short outages; automatic reconnect
   after longer ones is still manual (the Reconnect panel).
2. **Clipboard beyond text.** Text works both ways; files, and live verification of images, HTML and
   RTF, are open.
3. **File transfer** (client drive mapping or `CTXFILE`). Attachments and exports need to cross.
4. **Printing.** There is no client printer path at all.
5. **Audio out.** Notification sounds and alerts; microphone and webcam follow (Teams optimisation
   is a separate, larger piece).
6. **Per-app Dock / Cmd-Tab identity and app icons.** The windows switch correctly, but all remote
   apps share one Dock entry.
7. **Retina rendering.** Text is soft on HiDPI screens; the host renders at 1x.
8. **Session management** (Connection Center, session sharing, full-desktop launch). Needed for
   cleanup after a crash and for running a second app without a second session.

Not listed because they matter only in particular deployments: smart card, FIDO2, pass-through,
Citrix Cloud, App Protection, EPA, GACS, auto-update.

## Where ICAViewer exceeds stock

**Native window integration on macOS.** In the stock Mac client (Citrix Viewer 26.09), seamless
windows are borderless windows that Accessibility reports as `AXDialog` without title-bar buttons.
Some third-party window switchers require a standard window with a minimize button and therefore
skip them. The Dock icons come from placeholder "Husk" processes (`com.citrix.ctxapphusk`) that own
no windows, controlled by `enableAppDockEnhancement` / `EnableAppPreview`. In ICAViewer each remote
window is an `AXStandardWindow` with an enabled minimize button that round-trips to a TWI minimise,
a single caption (the remote one), and no helper processes. Verified across two screens. The one
open piece is per-app Dock/Cmd-Tab identity (gap 6).

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
