# 9. Displays and scaling

## Retina sharpness

On a Retina screen, ICA Viewer draws the remote apps at twice the resolution, so text and icons are as sharp as on your Mac. This is the **Auto** setting and needs nothing from you.

If the session would become too large for the protocol (it limits the picture to 5120 × 4096 pixels), for example with two large Retina screens, ICA Viewer falls back to normal resolution (1x) for that session. **Settings** shows a note that explains this and what size it saw.

## Two scaling settings

In **Settings > Display** ([Settings](12-settings.md#scaling)) two settings control how big things look:

- **Windows scaling** is the zoom Windows itself applies, like **Display > Scale** on Windows: **Auto (matches client scaling)** or a fixed value from 100 % to 200 %. Higher values make text and controls bigger in every remote app.
- **Client scaling** is how many screen pixels ICA Viewer uses for one point on your Mac: **Auto (2x on Retina screens)**, **1x** or **2x**. **1x** is less sharp but needs less data and less memory.

Under both, a line shows what the current or last session actually used, for example "Session 2560 × 1600 px, client 2x, Windows 200 %".

Scaling applies when a session connects. If you change it while a session is open, Settings offers a **Reconnect Now** button (ICA Viewer may also ask **Reconnect now to apply?**). **Reconnect Now** disconnects the session and connects again with the new scaling. The session is not logged off, and your apps keep running.

## Several screens

Remote windows can be on any of your screens. ICA Viewer reports all your screens to the server when a session connects, so a window can be moved from one screen to another. If you plug in or remove a screen later, reconnect the session so the server learns about the new layout.

## The menu bar

To the server, each of your screens starts below the Mac menu bar. A Windows app in full screen (for example Remote Desktop Connection, a slide show, or a browser in full-screen mode) therefore fills the space below the menu bar, and bars at its top edge stay clickable. If the menu bar is set to hide automatically, the whole screen height is used. A change to that setting applies from the next time you connect.

## Slow connections

**Compress screen data** (in **Settings > Display**) asks the server to compress what it sends. It is on by default and typically reduces the data to about a quarter. The change applies from the next time you connect.
