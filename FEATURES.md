# Feature matrix: stock Citrix Workspace app vs ICAViewer

ICAViewer is an independent project and is not affiliated with Citrix. The stock columns summarise
Citrix's public documentation (links under Sources). The Ours column describes ICAViewer v0.10.1 as
of 2026-11-19; how each feature behaves is described in the README and under `docs/`.

## At a glance

- **Works, verified live:** gateway logon with password and one-time code, StoreFront directly without a
  gateway, seamless apps as native Mac windows with their own Dock entries, several apps in one
  session, a published desktop in one window, reconnect and survival of network drops, Thinwire and
  H.264 graphics, Retina scaling, text, image, rich text and file clipboard, a shared client drive,
  audio playback, the microphone, the webcam (32- and 64-bit apps and Edge), PDF printing, links opening in the Mac's browser, the keyboard layout announced at sign-in, sign-out, and an
  indicator for features the server refuses.
- **Built, not yet verified by hand:** the automatic reconnect after a long drop is verified in the lab, a
  by-hand Wi-Fi test is open.
- **Main gaps:** several monitors for a desktop, HTML on the clipboard (the
  server filters it), SAML, smart card and FIDO2, USB devices, UDP transport (an experimental path
  exists, off), Teams optimization.

## How to read the tables

| Word | In the stock columns | In the Ours column |
|---|---|---|
| Yes | Citrix lists it as supported | Works, verified live |
| Built | – | Implemented, not yet verified live |
| Partly | Supported with a limit; see Notes | Part of the feature; see Notes |
| Likely | Not on any page read; general product knowledge | – |
| No | Listed as not supported | Not implemented |
| ? | Not found in the pages read | Not tested |
| – | Not applicable | – |

- Stock cells come from Citrix's **feature matrix** (page dated 2026-10-30; Windows = Current
  Release). A release number in Notes (for example "Mac 2607") means the platform's What's new page.
  The matrix lags those pages (it names Mac 2511.1 and Linux 2601), so where they disagree the cell
  follows the newer page and the note says so.
- "Yes" means "listed as supported", not "works as well as on Windows".
- The pages were read through a summarising fetch tool, and the long What's new pages only in part.
  Spot-check a cell before relying on it. The evidence for each cell is in
  `notes/feature-matrix-research-2026-11-13.md`.

## Sign-in and stores

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| StoreFront through NetScaler Gateway | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | |
| StoreFront direct, without gateway | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Ours: verified live against the lab StoreFront, with CGP and raw ICA ports |
| Citrix Cloud (Workspace) stores | Yes | Yes | Yes | Yes | Yes | Yes | Yes | No | |
| Anonymous store access | Yes | Yes | Yes | Yes | Yes | Yes | Yes | ? | |
| Store set-up from an email address | Yes | Yes | No | No | No | Yes | Yes | No | |
| Password plus one-time code (nFactor form) | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | |
| NetScaler native one-time code (OTP) | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Ours: typed, or computed from a secret in the Keychain |
| SMS challenge (RADIUS) | Yes | Yes | No | No | No | No | No | No | |
| Federated logon (SAML, Entra ID) | Yes | Yes | Yes | Yes | Yes | Yes | Yes | No | |
| Save the login | Yes | Yes | No | No | No | No | No | Yes | Stock: on-premises StoreFront only. Ours: Keychain |
| Credential insertion for scripts | Yes | No | Yes | No | Yes | No | No | No | Fast Connect, Storebrowse |
| Smart card logon | Yes | Yes | Yes | No | Yes | Yes | Yes | No | |
| Contactless card logon | Yes | No | Yes | No | Yes | No | No | No | |
| User certificate through the gateway | No | No | No | Yes | Yes | Yes | Yes | No | Native app; the browser variant differs |
| Pass-through of the Windows login | Yes | No | No | No | No | No | No | No | Entra ID single sign-on is a different feature |
| Passkey / FIDO2 logon | Likely | Yes | Yes | ? | ? | Yes | Yes | No | Mac 2603, Linux 2601, iOS 24.5, Android 26.7 |
| Touch ID / Face ID logon | No | No | No | No | No | Yes | No | No | The Mac uses Touch ID only for passkeys |
| Full VPN through NetScaler | Yes | Yes | Yes | No | No | No | No | No | |
| Web and SaaS apps with single sign-on | Yes | Yes | Yes | Yes | Yes | Yes | Yes | No | |
| Secure Private Access | Yes | Yes | No | No | No | Yes | Yes | No | |

## Launching and sessions

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Seamless published apps | Likely | Partly | ? | Partly | ? | Partly | Partly | Yes | Mac: borderless windows (see below). Web: inside a browser tab. Mobile: inside a session view, unverified |
| Full desktops | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Partly | Ours: one published desktop opens in one fixed-size window (verified in a VM); no multi-monitor desktop |
| Desktop Viewer toolbar | Yes | Yes | Yes | Yes | Yes | Yes | Yes | No | |
| Several apps in one session | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Ours: no second logon |
| Reconnect to a disconnected session | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Ours: also offered at start |
| Session list (Connection Center) | Likely | ? | ? | ? | ? | ? | ? | Yes | Ours: reconnect, take over, disconnect, log off; shows features the server refuses and an unencrypted connection |
| Local App Access | Yes | No | No | No | No | No | No | No | |

## Network

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| TLS to the gateway | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | |
| TLS 1.3 | Yes | Yes | Yes | No | Yes | Yes | Yes | Yes | Ours: system TLS; the log names the version and cipher of every connection (from 0.11.0). Lab: StoreFront and the VDA TLS 1.3 (AES-256-GCM), EDT over DTLS 1.2 (ECDHE-RSA AES-256-GCM) |
| TLS 1.0 / 1.1 | No | Yes | No | Yes | Yes | No | No | ? | |
| Survives short network drops (session reliability) | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Up to the server's timeout, typically 180 s |
| Reconnects after longer drops (auto client reconnect) | Yes | Yes | Yes | Partly | Yes | No | Yes | Yes | Web: matrix no, HTML5 2607 yes. Ours: after a longer outage the app is relaunched through the store, which brings the session back by itself (verified in the lab: a 240 s outage, and a 60 s outage with resume in the VM); direct, gateway-less sessions get no reconnect ticket from the VDA, so the store relaunch is the long-outage path. A by-hand Wi-Fi test is still open |
| UDP transport (EDT) | Yes | Yes | Yes | Partly | Yes | Yes | Yes | Partly | Web: matrix no, HTML5 2603 mentions EDT Reliable. Ours: from 0.11.0 follows the ICA file's HDXoverUDP (Off: TCP; Preferred: EDT races TCP, TCP within 300 ms if UDP does not answer; On: EDT only, with a message if UDP is blocked), on direct connections with session reliability, also over DTLS; not through a gateway. Verified in the lab, including resume after outages (1.5 to 8 times the throughput of TCP under latency and loss) |
| EDT lossy mode | Yes | Yes | Yes | ? | Yes | Yes | Yes | No | Release notes only |
| DTLS 1.2 (EDT through the gateway) | Yes | Yes | Yes | No | No | Partly | No | No | iOS 24.7 lists it, matrix says no. Mac dropped DTLS 1.0 in 2603.11. Ours: DTLS 1.2 straight to the VDA (lab verified, see the row above), not through a gateway |
| Direct VDA connection (HDX Direct) | Yes | Yes | Yes | Partly | Partly | ? | Partly | No | Release notes only; Web, ChromeOS, Android mention it in passing |
| ICA stream compression (server → client) | Likely | Likely | Likely | Likely | Likely | Likely | Likely | Yes | Ours: on by default (Settings › Network), about a quarter of the data in a live test; client → server stays uncompressed |
| Multi-port ICA | Yes | No | Yes | No | No | No | No | No | |
| SD-WAN support | Yes | Yes | Yes | Yes | Yes | No | No | ? | |

## Graphics and displays

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Thinwire classic | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | |
| H.264 | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Ours: 4:2:0 and 4:4:4 decode verified in the lab |
| H.265 / AV1 | Yes | Partly | Partly | ? | ? | ? | ? | No | Mac, Linux: H.265 only. Ours: not offered; the lab VDA (no GPU) sends H.264 even with the H.265 policy on, to the stock client too |
| Full colour (YUV 4:4:4) | Yes | Yes | ? | ? | ? | ? | ? | Yes | Ours: from 0.11.0, offered only when the Mac's hardware decoder passes a test decode at start (Apple silicon does; the software decoder refuses 4:4:4). With the server's visually-lossless policy about 7 times less bandwidth and 4 times less CPU than lossless bitmaps (lab) |
| Hardware video decoding | Yes | Yes | Yes | No | No | No | Yes | Yes | Ours: VideoToolbox, the H.264 path |
| Desktop composition redirection | Yes | No | No | No | No | No | No | No | |
| Several monitors as one desktop | Yes | Yes | Yes | Yes | Yes | Partly | Partly | Yes | iOS, Android: external monitor only. Ours: size fixed per session |
| Retina / HiDPI scaling | Likely | ? | ? | Yes | ? | Yes | Yes | Yes | Ours: 2x on Retina, 1x above 5120 × 4096 |
| Adaptive throughput | Yes | No | No | Yes | Yes | No | No | Partly | Ours: own frame-rate limit (5 to 30 fps) |

## Mac window integration

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Remote windows are real OS windows | Likely | Partly | ? | No | ? | No | No | Yes | Mac: borderless, without title-bar buttons (see below) |
| Own Dock / taskbar entry per remote app | Likely | Partly | ? | No | ? | No | No | Yes | Mac: placeholder processes that own no windows |
| Visible to window switchers | Likely | Partly | ? | No | ? | No | No | Yes | |
| Real app icons | Likely | Yes | ? | ? | ? | ? | ? | Yes | |

## Keyboard, mouse and touch

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Keyboard layout sync to a Windows VDA | Yes | Yes | Yes | No | No | Yes | Yes | Yes | Ours: the Mac's input source at sign-in (DE, US, UK, FR, CH, NL, ES, IT, Dvorak and more); after a switch, characters go as text; verified headless and in the macOS test VM |
| Keyboard layout sync to a Linux VDA | Yes | Yes | Yes | No | No | Yes | Yes | ? | |
| Scancode keyboard mode | Yes | Yes | Yes | Yes | Yes | No | No | Yes | |
| Unicode keyboard mode | No | Yes | Yes | Yes | Yes | Yes | Yes | Partly | Ours: Option-composed characters (€, @; such an Option never acts as Alt), dead keys composed by the Mac layout (ê, ñ), the emoji picker (Emoji & Symbols; typing in its search field not yet), and printable keys while the Mac layout differs from the logon layout; Cmd and Ctrl shortcuts stay keys, letters and + - , . placed by the session's layout (D141, D160, D167). Not built: press-and-hold accents and Mac input methods |
| Local input method for Chinese, Japanese, Korean | Yes | Yes | No | Yes | Yes | Yes | Yes | No | CTXIME |
| Server input method for Chinese, Japanese, Korean | Yes | Yes | Yes | Yes | Yes | Yes | Yes | ? | Ours: needs only key events |
| Mouse and wheel | Likely | Likely | Likely | Likely | Likely | Likely | Likely | Yes | |
| Relative mouse | ? | ? | ? | ? | ? | ? | ? | ? | |
| Touch and gestures | Yes | No | Yes | Yes | Yes | Yes | Yes | No | Mac 2603: gestures only into Citrix's macOS VDA. Pen: no page read |

## Clipboard, files and links

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Clipboard: plain text | Likely | Yes | Yes | Yes | ? | ? | ? | Yes | |
| Clipboard: formatted text, images | Likely | Yes | Yes | Partly | ? | ? | ? | Yes | Web: HTML confirmed, images not. Ours: images and RTF (also with a picture) verified both ways with WordPad and LibreOffice Writer; HTML does not cross (the server filters it) |
| Clipboard: files | Likely | Yes | Yes | ? | ? | ? | ? | Yes | Ours: both ways over CTXGDT, Finder and Explorer, folders included, with a progress window above 50 MB; verified live in a VM. Throughput depends on the server pacing |
| Local folder in the session (client drive) | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Ours: one shared folder as drive M, verified live (the read bug is fixed) |
| File transfer (upload, download) | Likely | Likely | Likely | Likely | Likely | ? | ? | No | Not a matrix row. Ours: under investigation |
| Open a local file in a remote app | Yes | Partly | Yes | No | Yes | Yes | Yes | No | Mac: matrix no, but Mac 2411 added file type association |
| Links in remote apps open on the client | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Host-to-client URL redirection. Mac: seen in the stock client's own traffic (http/https only, after a reachability check, no prompt). Ours: from 0.11.0, when the server's policy "Host to client redirection" is on, http/https links open in the Mac's default browser; other schemes, local addresses, unreachable servers and more than 5 links in 30 s stay in the session (docs/56); verified in the lab |
| Links in both directions | Yes | Yes | Yes | No | No | No | No | No | Bidirectional redirection (browser extensions on both sides); Mac since 2603. Ours: host to client only (row above) |

## Devices

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Printing to client printers | Yes | Yes | Yes | Yes | Yes | Yes | No | Yes | Ours: the session PDF printer delivers a PDF to the Mac, verified to a valid PDF; off by default |
| Any USB device (generic USB) | Yes | Yes | Yes | Yes | Yes | Yes | Yes | No | Mac docs describe storage devices |
| Smart card in the session | Likely | ? | Likely | ? | Partly | ? | ? | No | ChromeOS: through generic USB |
| FIDO2 / WebAuthn in the session | Yes | Yes | Yes | ? | ? | ? | ? | No | Windows 2402, Linux 2303, Mac 2307 and later |
| Scanners | Yes | No | Partly | No | Yes | No | No | No | Windows: TWAIN, WIA (not LTSR). Linux: SANE. ChromeOS 2411.1; matrix says no |
| Webcam | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Ours: verified live with a camera in a test VM, 32- and 64-bit apps and Edge (352×288, 15 fps); on by default, used only while a session app plays it |
| Audio playback | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | |
| Microphone | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Yes | Ours: on by default from 0.9.0; opens only while a session app records, macOS asks at the first recording; a menu-bar item while recording with "Disable Microphone for This Session"; Opus |
| Audio over UDP | Yes | No | Yes | No | No | No | No | No | |
| Location | Yes | Partly | No | No | No | Yes | Yes | No | Mac 2607 preview; matrix says no |
| Mobile device features (mobility pack) | Yes | No | No | Yes | Yes | Yes | Yes | No | |
| Battery status in the session | Likely | ? | Yes | ? | ? | ? | ? | No | Release notes only (Linux 2503) |
| Client time zone in the session | Likely | Yes | Likely | Yes | Likely | Likely | Likely | Yes | Not a matrix row. Mac: seen in the stock client's own traffic. Ours: from 0.11.0 the Mac's time zone (Windows name, offset, daylight-time rules), used when the server's policy "Use local time of client" says so (Windows Server VDAs also need "Allow time zone redirection"); verified in the lab for 6 zones incl. half-hour offsets and southern daylight time |
| COM / serial ports | Likely | ? | ? | ? | ? | ? | ? | No | |

## Meetings and media

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Microsoft Teams optimisation | Yes | Yes | Yes | Yes | Yes | No | No | No | Mac: new Teams since 2607. Ours: not planned |
| Zoom / Webex optimisation | Yes | Yes | ? | ? | Yes | ? | ? | No | Mac, ChromeOS: Zoom |
| Cisco Jabber optimisation | Yes | No | Yes | No | No | No | No | No | |
| Skype for Business optimisation | Yes | Yes | Yes | No | No | No | No | No | |
| Unified Communications SDK | Yes | Yes | Yes | Yes | Yes | No | No | No | |
| Browser content redirection | Yes | Yes | Yes | No | Yes | No | No | No | |
| Windows media redirection | Yes | No | Yes | No | No | No | No | No | |

## Security

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Secure ICA encryption | Likely | ? | Yes | Likely | Likely | Yes | Yes | No | Ours: not needed over TLS; no server asked for it |
| App Protection | Yes | Yes | Yes | No | No | Yes | Yes | No | Linux as listed; verify before relying on it |
| Endpoint analysis (EPA) | Likely | ? | Yes | ? | ? | ? | ? | No | Ours: the tested gateway has no EPA step |

## Management and support

| Feature | Win | Mac | Linux | Web | ChromeOS | iOS | Android | Ours | Notes |
|---|---|---|---|---|---|---|---|---|---|
| Global App Config service | Yes | Yes | No | Yes | Yes | Yes | Yes | No | |
| Centralised management settings | Yes | No | Yes | No | Yes | No | No | No | |
| Client App Management | Yes | No | No | – | – | – | – | No | |
| Auto-update | Yes | Yes | No | No | No | Partly | Partly | No | iOS, Android: through the app stores |
| Usage metrics to Citrix Director (EUEM) | Yes | Yes | Yes | Yes | Yes | No | Yes | No | Ours: no telemetry, by design |
| Network analytics (HDX Insight, AppFlow) | Yes | Yes | Yes | Partly | Partly | Partly | Partly | No | Web, ChromeOS: no NSAP channel. iOS, Android: NSAP only. Ours: by design |
| Command-line tool | Yes | No | No | No | No | No | No | Yes | Ours: `icactl`, for testing |
| In-app problem report | ? | ? | ? | ? | ? | ? | ? | Yes | Ours: scrubbed, previewed before sharing |

Left out: matrix rows for the mobile apps only (RSA soft token, single sign-on to Citrix mobile
apps, Lockdown mode, auto-launch, connection strength indicator, App Store updates), rows about
settings screens (keyboard sync, input mode, language bar), keyboard layout sync from the VDA to
the client (no on every platform), and Citrix Enterprise Browser (deprecated; removed in Linux 2604).

## Stock Mac viewer components

The stock Mac viewer (Citrix Viewer 26.09.0.25, inside
`/Library/Application Support/Citrix Receiver/`) ships most virtual channels as separate plug-in
bundles. The table below is built from the bundle names and the controller class named in each
bundle's `Info.plist`; no binary was opened. Thinwire graphics and seamless windows (TWI) are part of
the main viewer, not plug-ins. Where the feature column says "probably", the name is the only hint.

| Bundle (controller class) | Feature, matrix row | **Ours** |
|---|---|---|
| `CTXCAM` (`ICAClientAudioController`) | Audio out, microphone | Yes |
| `CTXCLIP` (`ICAClipboardController`) | Clipboard | Partly |
| `CTXCDM` (`ICAClientDriveController`) | Client drive mapping | Partly |
| `CTXGDT` (`ICAClientGDTController`) | File transfer (generic data transfer) | Partly: clipboard files (docs/76-gdt.md §7.17, D90) |
| `CTXCPM` (`ICACPMVirtualChannel`) | Printing | Partly |
| `CTXCTL` (`ICAControlChannelController`) | Control channel (launch into a running session) | Yes |
| `CTXMM` (`ICAClientMultimediaController`) | Multimedia; ICAViewer's webcam uses this channel | Partly (webcam only) |
| `CTXMTOP` (`ICAClientMTOPController`) | Probably Teams / WebRTC optimisation: the largest bundle (8.2 MB), next to `libbgblur.dylib` | No |
| `CTXSCRD` (`ICAClientSCardV2Controller`) | Smart card into session | No |
| `CTXFIDO` (`ICAClientFido2Controller`) | FIDO2 inside the session | No |
| `CTXIME` (`ICAIMEVirtualChannel`) | Client IME | No |
| `CTXMTCH` (`ICAMultiTouchController`) | Touch / gestures | No |
| `CTXSCAN` (`ICAClientScanController`) | Scanners; shipped although no Mac page lists scanner redirection | No |
| `CTXGUSB` (`ICAUSBVirtualChannel`), with `CTXUSBDaemon.framework` | Generic USB | No |
| `CTXBCR`, `CTXBCRPF` (`ICAClientBCRController`, `…BCRPFController`) | Browser content redirection | No |
| `CTXSENS` (`ICAClientSENSController`) | Probably location / sensors (Mac 2607 preview) | No |
| `CTXMOB` (`ICAClientMobileController`) | Mobility pack; shipped although the matrix says Mac has none | No |
| `CTXAPPP` (`ICAAppProtectionController`) | App Protection | No |
| `CTXEUEM` (`ICAUserExperienceController`) | Experience metrics (EUEM) | No (by design) |
| `CTXNSAP` (`ICANSAPController`) | HDX Insight / NetScaler AppFlow | No (by design) |
| `CTXSUPP` (`ICAClientVdTelemetryController`) | Client telemetry | No (by design) |

Libraries next to them: `libUrlRedirection_client.dylib` (link redirection), `libudt.dylib`
(probably the UDP transport behind EDT), `libbgblur.dylib` (background blur), FFmpeg
(`libavcodec`, `libavformat`, `libswscale`) and OpenCV.

## Gaps that matter most

Ordered for daily use through a gateway with mail and line-of-business applications.

1. **Several monitors in a published desktop**, and more than one fixed-size window for it.
2. **File transfer** beyond clipboard files and the shared folder; HTML on the clipboard (filtered by the server).
3. **Authentication** beyond ExplicitForms with TOTP and plain StoreFront forms (SAML, smart card, FIDO2),
   USB devices, and HDX over UDP (experimental and off).

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
every row above that is marked No.

## Sources

Stock-client documentation (fetched 2026-11-05 unless noted):

- Feature matrix, dated 2026-10-30: https://docs.citrix.com/en-us/citrix-workspace-app/citrix-workspace-app-feature-matrix.html
- Mac, What's new (2409 to 2609): https://docs.citrix.com/en-us/citrix-workspace-app-for-mac/whats-new.html
- Mac 2603 release page: https://www.citrix.com/downloads/workspace-app/mac/workspace-app-for-mac-latest2603.html
- Linux, What's new (2601 to 2608): https://docs.citrix.com/en-us/citrix-workspace-app-for-linux/whats-new.html
- HTML5, What's new (2408 to 2607): https://docs.citrix.com/en-us/citrix-workspace-app-for-html5/whats-new.html
- iOS, What's new (25.9 to 26.9): https://docs.citrix.com/en-us/citrix-workspace-app-for-ios/whats-new.html
- Android, What's new (25.7 to 26.7): https://docs.citrix.com/en-us/citrix-workspace-app-for-android/whats-new.html
- Windows, About this release, dated 2026-11-04 (read in part): https://docs.citrix.com/en-us/citrix-workspace-app-for-windows/about.html
  (the `whats-new.html` and `about-this-release.html` URLs return only site navigation)
- Windows 2603.11 PDF (not opened): https://docs.citrix.com/en-us/citrix-workspace-app-for-windows/downloads/citrix_workspace_app_2603_11_for_windows.pdf
- Thinwire / codec negotiation (H.264, H.265, AV1, 4:4:4): https://docs.citrix.com/en-us/citrix-virtual-apps-desktops/2311/graphics/thinwire.html
- ChromeOS, What's new of the Chrome app, dated 2026-10-29 (read in part): https://docs.citrix.com/en-us/citrix-workspace-app-for-chrome/whats-new.html
  (`citrix-workspace-app-for-chromeos/whats-new.html` returns only site navigation)
- FIDO2 in the session, Virtual Apps and Desktops 2511: https://docs.citrix.com/en-us/citrix-virtual-apps-desktops/2511/secure/fido2/configuration

Pages fetched again on 2026-11-13: the feature matrix and the Mac, Linux, HTML5, iOS and Android
What's new pages (dated 2026-10-26 to 2026-11-13).
