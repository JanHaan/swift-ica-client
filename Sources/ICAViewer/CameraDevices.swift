import AVFoundation

/// The video devices the camera picker offers (docs/98b §10.5): built-in, external and Continuity Camera.
///
/// Listing uses `AVCaptureDevice.DiscoverySession` only. That neither opens a device nor asks for permission: on macOS
/// the camera prompt comes from `requestAccess` or from opening a device input, and both happen only at the host's PLAY
/// (`Camera`). Discovery is documented to work without authorization; in case a system returns nothing before access
/// was granted, `accessHint` explains the empty list instead of prompting.
enum CameraDevices {
    struct Device: Equatable {
        let id: String
        let name: String
    }

    static let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]

    /// The connected video devices, in discovery order. Never opens one.
    static func list() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// Posted when a device is connected or disconnected (Settings refreshes its list while open).
    static let changeNotifications: [Notification.Name] = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification]

    /// The device for a stored unique id, if it is connected (does not open it).
    static func device(id: String) -> AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id)
    }

    /// A hint for Settings when the list is empty because access was not granted (nil otherwise). Reads the
    /// authorization status only; never asks.
    static func accessHint(listEmpty: Bool) -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return nil
        case .denied, .restricted:
            return loc("Camera access is off for ICA Viewer (Privacy & Security → Camera).",
                       "Der Kamerazugriff ist für ICA Viewer aus (Datenschutz & Sicherheit → Kamera).")
        default:
            return listEmpty ? loc("Allow camera access to list devices (asked when a session app first uses the camera).",
                                   "Kamerazugriff erlauben, um Geräte anzuzeigen (gefragt, wenn eine Sitzungs-App die Kamera zuerst nutzt).") : nil
        }
    }
}
