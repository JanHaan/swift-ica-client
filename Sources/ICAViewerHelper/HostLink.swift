import AppHostKit
import Darwin
import Foundation

/// The helper's side of the channel (docs/99 §4–5): looks up the host's broker, checks in with the
/// token and a send right to its own receive port, and reports the host's end three ways: a dead-name
/// notification on the broker port, the host pid's exit, and a send that finds no receiver. A `hello`
/// that carries a port switches all later messages to that per-helper port.
final class HostLink {
    let launch: HelperLaunch
    private var host = mach_port_t(MACH_PORT_NULL)
    private var receiver: MachReceiver?
    private var exitWatch: DispatchSourceProcess?
    private var lostReported = false
    var onMessage: ((HostMessage, mach_port_t) -> Void)?
    var onLost: ((String) -> Void)?

    init(launch: HelperLaunch) { self.launch = launch }

    /// Blocks up to ~3 s for the broker name (the host checks in before launching, so normally at once).
    func connect(queue: DispatchQueue) -> String? {
        guard kill(launch.hostPid, 0) == 0 else { return "host pid \(launch.hostPid) is not running" }
        var found: mach_port_t?
        for _ in 0..<60 {
            found = MachChannel.lookUp(launch.broker)
            if found != nil { break }
            usleep(50_000)
        }
        guard let found else { return "bootstrap_look_up(\(launch.broker)) failed" }
        host = found
        guard let port = MachChannel.allocateReceivePort() else { return "cannot allocate a receive port" }
        let receiver = MachReceiver(port: port)
        self.receiver = receiver
        receiver.start(queue: queue) { [weak self] received in
            guard let self else { return }
            switch received {
            case .deadName:
                self.lost("host port died")
            case .message(let data, let port):
                guard let message = try? WireCoding.decode(HostMessage.self, from: data) else {
                    MachChannel.deallocate(port)
                    return
                }
                if case .hello = message, port != MACH_PORT_NULL {
                    // ICAViewer gives each helper its own port (the host knows the sender by it); the spike
                    // sends none and keeps receiving on the broker port.
                    let broker = self.host
                    self.host = port
                    self.receiver?.notifyDeadName(of: port)
                    MachChannel.deallocate(broker)      // the per-helper port and the pid watch report the host's end
                    self.onMessage?(message, mach_port_t(MACH_PORT_NULL))
                    return
                }
                self.onMessage?(message, port)
            }
        }
        receiver.notifyDeadName(of: host)
        let watch = DispatchSource.makeProcessSource(identifier: launch.hostPid, eventMask: .exit, queue: queue)
        watch.setEventHandler { [weak self] in self?.lost("host exited") }
        watch.resume()
        exitWatch = watch
        let kr = MachChannel.send(HelperMessage.checkIn(token: launch.token, pid: getpid()), to: host, port: port,
                                  disposition: mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
        return kr == KERN_SUCCESS ? nil : "check-in send failed: \(kr)"
    }

    /// `timeoutMs` 0 for messages that may be dropped when the host is busy.
    func send(_ message: HelperMessage, timeoutMs: UInt32 = 200) {
        let kr = MachChannel.send(message, to: host, timeoutMs: timeoutMs)
        if kr == MACH_SEND_INVALID_DEST { lost("host port invalid") }
    }

    private func lost(_ reason: String) {
        guard !lostReported else { return }
        lostReported = true
        onLost?(reason)
    }
}

func helperLog(_ message: String) {
    FileHandle.standardError.write(Data("[helper \(getpid())] \(message)\n".utf8))
}
