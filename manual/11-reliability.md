# 11. Session reliability and automatic reconnect

Networks drop: you walk to another room, Wi-Fi changes, the Mac sleeps for a minute. ICA Viewer keeps your session alive through this in two steps.

## Short drops: the session simply continues

With **session reliability**, ICA Viewer and the server hold the session open when the connection is lost. Your windows stay where they are but are dimmed, and a small panel counts down while ICA Viewer reconnects:

![Illustration: windows are dimmed and a panel counts down while the connection is restored](images/demo-hud.png)

When the network is back, the windows brighten and the session continues exactly where it was, with nothing lost. The server keeps the session for a limited time, typically 180 seconds. The countdown shows the time left.

You can press **Reconnect Now** to try at once, or **Close** to give up.

## Longer drops: reconnect automatically

If the network is gone for longer than the server waits, the session is cut. ICA Viewer then reconnects it for you through the store: it waits for the network (up to 10 minutes), tries again, and brings your apps back to this Mac. Your apps kept running on the server, so you continue where you stopped. A panel tells you what is happening ("Connection lost. Reconnecting automatically in 0:20…", "No network. Waiting for it…", "The network is back. Reconnecting…").

If it does not succeed, ICA Viewer shows a panel with the reason and a **Reconnect** button:

![Illustration: the panel after the automatic reconnect gave up](images/demo-gaveup.png)

You can also reconnect any time from the [Connection Center](10-connection-center.md) or the launcher.

## Choose the behavior

In **Settings > General**, **Connection drop** ([Settings](12-settings.md#connection-drop)):

- **Reconnect automatically** (default): ICA Viewer reconnects after a longer drop by itself.
- **Ask**: ICA Viewer asks first.

Short drops are always bridged automatically.

## Notes

- The two screenshots in this chapter are illustrations from the app's demo mode. The test lab cannot cut the network on demand while the pictures are taken.
- When the Mac sleeps for a long time, the session may have been ended by the server. Use **Reconnect**; if your apps are gone, start them again from the launcher.
