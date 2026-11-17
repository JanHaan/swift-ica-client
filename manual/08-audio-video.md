# 8. Audio, microphone and webcam

## Sound from the session

Sound from remote apps plays on your Mac and follows your Mac's volume. This is on by default. To turn it off, clear **Play session sounds** in **Settings > Devices** ([Settings](12-settings.md#audio-and-camera)); the change applies from the next time you connect.

If your server blocks audio, the [Connection Center](10-connection-center.md#features-the-server-refuses) shows "Audio: blocked by server policy" and the app plays no sound.

## Microphone

The microphone is **off by default**. To use it, for example for a voice recorder or a call in a remote app:

1. In **Settings > Devices**, tick **Pass the microphone to the session**.
2. Start a session. When a remote app starts recording, macOS asks whether ICA Viewer may use the microphone. Click **OK**.

ICA Viewer sends sound to the session only while an app in the session is recording. While it does, a microphone icon appears in the menu bar. Click it to see **Microphone: recording** and the item **Disable Microphone for This Session**, which stops it for the current session at once.

If you refused the permission, ICA Viewer says so and offers **Open Privacy Settings**; allow ICA Viewer under **System Settings > Privacy & Security > Microphone**.

## Webcam

The webcam is **off by default** too. In **Settings > Devices**, tick **Pass the camera to the session** and, if you have several cameras, pick one in the list below it (the default is **Automatic (system default)**). macOS asks for permission the first time a remote app starts the camera.

- The camera is used only while a remote app uses it. A camera icon appears in the menu bar. Click it to see **Camera: in use** and **Disable Camera for This Session**.
- **Only 32-bit Windows apps can use this webcam path.** Modern 64-bit apps (for example Windows Camera, Teams or browsers) will not see the camera.
- The camera passes through as video that ICA Viewer encodes on your Mac. It has not been tried with every kind of camera.

The lab used for this manual has no microphone or camera, so these two features have no screenshots.
