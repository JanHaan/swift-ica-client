# 8. Audio, microphone and webcam

## Sound from the session

Sound from remote apps plays on your Mac and follows your Mac's volume. This is on by default. To turn it off, clear **Play session sounds** in **Settings > Devices** ([Settings](12-settings.md#audio-and-camera)); the change applies from the next time you connect.

If your server blocks audio, the [Connection Center](10-connection-center.md#features-the-server-refuses) shows "Audio: blocked by server policy" and the app plays no sound.

## Microphone

The microphone is **on by default**. To use it, for example for a voice recorder or a call in a remote app:

1. Start a session and start recording in the remote app.
2. The first time, macOS asks whether ICA Viewer may use the microphone. Click **Allow**. The remote app waits for your answer.

ICA Viewer sends sound to the session only while an app in the session is recording. While it does, a microphone icon appears in the menu bar. Click it to see **Microphone: recording** and the item **Disable Microphone for This Session**, which stops it for the current session at once.

If you refused the permission, ICA Viewer says so and offers **Open Privacy Settings**; allow ICA Viewer under **System Settings > Privacy & Security > Microphone**.

To never pass the microphone, clear **Pass the microphone to the session** in **Settings > Devices** ([Settings](12-settings.md#audio-and-camera)); the change applies from the next time you connect.

## Webcam

The webcam is **on by default**. To use it, for example for a video call in a remote app:

1. Start a session and start the camera in the remote app.
2. The first time, macOS asks whether ICA Viewer may use the camera. Click **Allow**. The remote app waits for your answer.

If you have several cameras, pick one in **Settings > Devices** in the list below **Pass the camera to the session** (the default is **Automatic (system default)**).

- The camera is used only while a remote app uses it. A camera icon appears in the menu bar. Click it to see **Camera: in use** and **Disable Camera for This Session**.
- Remote apps see it as **Citrix HDX Web Camera**. It was tried with 32-bit and 64-bit Windows apps and with Microsoft Edge.
- If you refused the permission, ICA Viewer says so and offers **Open Privacy Settings**; allow ICA Viewer under **System Settings > Privacy & Security > Camera**.
- To never pass the camera, clear **Pass the camera to the session** in **Settings > Devices** ([Settings](12-settings.md#audio-and-camera)); the change applies from the next time you connect.
- The camera passes through as video that ICA Viewer encodes on your Mac. It has not been tried with every kind of camera.

The lab used for this manual has no microphone or camera, so these two features have no screenshots.
