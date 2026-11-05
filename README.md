# swift-ica-client

ICAViewer, an independent, native macOS client for published applications delivered over the ICA
protocol, written in Swift. Each seamless remote window becomes a real macOS window: an
`AXStandardWindow` with a working minimize button and a single (remote) title bar. Cmd-Tab, Mission
Control and third-party window switchers handle them like local windows.

This is a personal interoperability project, built for and tested against one environment
(NetScaler Gateway with nFactor, StoreFront, VDAs serving classic Thinwire). It is not a product
and not a replacement for the official client. Expect gaps; see [Status](#status).

> **Not affiliated with Citrix.** Citrix, ICA, HDX, NetScaler and StoreFront are trademarks of
> Cloud Software Group, Inc. They are used here only to describe what this software
> interoperates with. This project contains no code from any Citrix product.

## What works

- Gateway logon (nFactor ExplicitForms with username, password and TOTP passcode), store resource
  list and launch, from a native login window generated from the gateway's own form definition.
- Optional credential storage in the macOS Keychain (this device only), with Touch ID or password
  required before the TOTP secret is read.
- TLS to the gateway, CGP with session reliability: the session survives network drops, Wi-Fi
  changes and short sleeps (up to the server's reliability timeout, typically 180 s), with dimmed
  windows and a countdown while reconnecting.
- ICA handshake, V3 framing, keyboard (scancodes) and mouse input.
- Thinwire classic graphics (the GDI-style command set, caches, pointer shapes), double-buffered,
  with an adaptive frame-rate limit. An H.264 path (VideoToolbox) exists but is untested.
- Seamless windows (TWI): native windows and popups, local move and resize without round trips,
  minimise, multi-monitor sessions spanning all screens.
- Reconnecting to an existing disconnected session.

## Status

See [FEATURES.md](FEATURES.md) for a feature-by-feature comparison with the official clients.

Clipboard: text works both ways; HTML, RTF and images are implemented but not yet verified.
Not implemented yet: Retina rendering and DPI scaling, client drive
mapping and file transfer, printing, audio, microphone and webcam, a connection centre, session
sharing, one Dock entry per remote app, EDT/UDP, other authentication methods (SAML, smart card,
FIDO2). Only seamless app launches are exercised; full desktops are untested.

## Requirements

- macOS 14 or later, Swift 6 toolchain (Xcode 16 or newer).
- An environment reachable through a NetScaler Gateway with an ExplicitForms nFactor policy.

## Build and run

```sh
swift build
swift test
scripts/bundle.sh            # release build wrapped as .build/ICAViewer.app
open .build/ICAViewer.app
```

`bundle.sh` signs ad hoc by default. With a provisioning profile at
`signing/ICAViewer.provisionprofile` it signs with your Apple Development identity and the
Keychain entitlements, which enables Keychain-enforced Touch ID protection
(`scripts/fetch-profile.sh` describes how to obtain one; profiles never go into git). Set your own
team in `signing/project.yml`.

On first start ICAViewer asks for the gateway URL and your credentials.

## Command-line tool

`icactl` drives the same library without a UI, mainly for testing:

```sh
swift run icactl login                  # gateway logon, cookies saved in .session/
swift run icactl session "<resource>"   # headless session, captures channel data to .session/
swift run icactl droptest "<resource>"  # session with one forced link drop and a resume
```

Configuration for automated runs comes from a `.env` file in the package root (git-ignored):

```sh
CITRIX_GATEWAY_URL=https://gateway.example.com
CITRIX_USERNAME=...
CITRIX_PASSWORD=...
CITRIX_TOTP_SECRET=...      # base32; optional, otherwise you are prompted for the passcode
CITRIX_DOMAIN=...           # optional
```

`.session/` holds cookies, launch files and captures. It is git-ignored and must never be shared:
it contains session tickets and screen content.

## Layout

| Path | Contents |
|---|---|
| `Sources/ICAKit` | Gateway/store client, TLS, CGP, Winstation driver, Thinwire, TWI |
| `Sources/ICAViewer` | AppKit app: login, settings, remote windows, input |
| `Sources/icactl` | Command-line tool |
| `Tests/ICAKitTests` | Unit tests and offline end-to-end tests |
| `scripts`, `signing` | App bundling and code signing |

## How this was made

The protocol knowledge was obtained for interoperability under Art. 6 of Directive 2009/24/EC
(§69e of the German Copyright Act), from a lawfully obtained client, from public documentation, and
from observing the author's own sessions. The implementation was written independently from
those notes. The notes themselves are not published.

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option. See
[LICENSE](LICENSE).
