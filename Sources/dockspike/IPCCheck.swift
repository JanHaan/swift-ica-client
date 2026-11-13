import AppHostKit
import CoreGraphics
import Foundation
import IOSurface

/// `dockspike ipc-check`: the non-GUI half of the spike. Generates a relabelled, ad-hoc re-signed
/// helper in a temp directory, runs its executable with `--headless` (no AppKit, no windows), and checks:
/// 1. bootstrap rendezvous and check-in with a token;
/// 2. the IOSurface arrives by Mach port and is the same memory (a repaint is visible without a resend);
/// 3. round-trip latency of small messages;
/// 4. the helper exits on `quit`, and on its own when the host dies without one.
enum IPCCheck {
    private static let probes = 500

    static func run(template: URL) -> Never {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("dockspike-ipc-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        var failures: [String] = []
        func check(_ ok: Bool, _ text: String) {
            print("  \(ok ? "ok  " : "FAIL") \(text)")
            if !ok { failures.append(text) }
        }

        print("bundle:")
        let generator = HelperBundleGenerator(template: template, appsDirectory: temp, registerWithLaunchServices: false)
        let bundle: URL
        do {
            bundle = try generator.generate(HelperLabel(key: "dockspike.ipc-check", name: "IPC Check"),
                                            icon: Scene.icon(letter: "I", color: CGColor(red: 0.3, green: 0.6, blue: 0.3, alpha: 1))).url
        } catch {
            print("  FAIL generate: \(error)")
            exit(1)
        }
        let info = HelperBundleGenerator.readInfo(bundle) ?? [:]
        check(info["CFBundleIdentifier"] as? String == HelperBundle.bundleIdentifier(for: HelperLabel(key: "dockspike.ipc-check", name: "")),
              "relabelled: \(info["CFBundleIdentifier"] ?? "?") \"\(info["CFBundleName"] ?? "?")\"")
        let details = (try? HelperBundleGenerator.codesign(["-dv", bundle.path])) ?? ""
        check(details.contains("adhoc") && details.contains("runtime"),
              "signature: " + (details.split(separator: "\n").first { $0.hasPrefix("CodeDirectory") } ?? "?"))
        check((try? HelperBundleGenerator.verify(bundle)) != nil, "codesign --verify --strict")
        check(!HelperBundleGenerator.hasQuarantine(bundle), "no quarantine attribute")
        let exe = bundle.appendingPathComponent("Contents/MacOS/\(info["CFBundleExecutable"] as? String ?? "")")

        print("ipc (headless helper from the re-signed bundle):")
        let host = HeadlessHost(executable: exe)
        let result = host.run(probes: probes)
        check(result.checkedIn, "check-in via bootstrap_look_up + token")
        check(result.firstPixel == HeadlessHost.colorA, String(format: "surface pixel read in the helper: 0x%08x (expected 0x%08x)", result.firstPixel ?? 0, HeadlessHost.colorA))
        check(result.secondPixel == HeadlessHost.colorB, String(format: "after a host repaint, no resend: 0x%08x (expected 0x%08x) → shared memory", result.secondPixel ?? 0, HeadlessHost.colorB))
        if !result.rtts.isEmpty {
            let sorted = result.rtts.sorted()
            let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            print(String(format: "  round trip (host → helper reads a pixel → host), %d probes: p50 %.0f µs, p99 %.0f µs, max %.0f µs",
                         sorted.count, p(0.5), p(0.99), sorted.last!))
        }
        check(result.rtts.count == probes, "\(result.rtts.count)/\(probes) probes answered")
        check(result.exitedOnQuit, "helper exits on quit")

        print("lifecycle (host dies without quit):")
        let orphan = orphanCheck(executable: exe)
        check(orphan.helperPid != nil, "child host started a helper (pid \(orphan.helperPid.map(String.init) ?? "?"))")
        check(orphan.exitedAfterHost, "helper exited after its host died" + (orphan.ms.map { " (\($0) ms)" } ?? ""))

        print(failures.isEmpty ? "PASS" : "FAIL (\(failures.count))")
        try? fm.removeItem(at: temp)
        exit(failures.isEmpty ? 0 : 1)
    }

    /// Runs `dockspike ipc-orphan <exe>` (a host that starts a headless helper, prints its pid and
    /// exits without quit) and waits for the helper to go away by itself.
    private static func orphanCheck(executable: URL) -> (helperPid: pid_t?, exitedAfterHost: Bool, ms: Int?) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["ipc-orphan", executable.path]
        let out = Pipe()
        child.standardOutput = out
        do { try child.run() } catch { return (nil, false, nil) }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        guard let pid = text.split(separator: "\n").compactMap({ $0.hasPrefix("helper ") ? pid_t($0.dropFirst(7)) : nil }).first else {
            return (nil, false, nil)
        }
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            if kill(pid, 0) != 0 { return (pid, true, Int(Date().timeIntervalSince(start) * 1000)) }
            usleep(10_000)
        }
        kill(pid, SIGKILL)
        return (pid, false, nil)
    }

    /// `ipc-orphan`: host role for `orphanCheck`.
    static func orphanHost(executable: URL) -> Never {
        let host = HeadlessHost(executable: executable)
        guard let pid = host.startAndWaitForCheckIn() else { exit(1) }
        print("helper \(pid)")
        fflush(stdout)
        _exit(0)        // no quit, no cleanup: as if the host crashed
    }
}

/// Host side of the headless check: broker, one helper process, a synchronous probe loop.
final class HeadlessHost {
    static let colorA: UInt32 = 0xFF33_6699
    static let colorB: UInt32 = 0xFFCC_5500

    struct Result {
        var checkedIn = false
        var firstPixel: UInt32?
        var secondPixel: UInt32?
        var rtts: [Double] = []
        var exitedOnQuit = false
    }

    private let executable: URL
    private let surface = SharedSurface.create(width: 64, height: 64)!
    private var helperPort = mach_port_t(MACH_PORT_NULL)
    private let queue = DispatchQueue(label: "dockspike.ipc")
    private let token = HelperLaunch.makeToken()
    private var receiver: MachReceiver?
    private var process: Process?
    private let checkedIn = DispatchSemaphore(value: 0)
    private let answered = DispatchSemaphore(value: 0)
    private var lastPixel: UInt32 = 0

    init(executable: URL) { self.executable = executable }

    static func fill(_ surface: IOSurfaceRef, _ argb: UInt32) {
        SharedSurface.draw(surface) { ctx in
            ctx.setFillColor(CGColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                                     blue: CGFloat(argb & 0xFF) / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
    }

    /// Checks in the broker, starts the helper and waits up to 3 s for its check-in; the helper's pid.
    func startAndWaitForCheckIn() -> pid_t? {
        Self.fill(surface, Self.colorA)
        let broker = HelperLaunch.brokerName(hostPid: getpid())
        guard let port = MachChannel.checkIn(broker) else {
            print("  bootstrap_check_in(\(broker)) failed")
            return nil
        }
        let receiver = MachReceiver(port: port)
        self.receiver = receiver
        receiver.start(queue: queue) { [weak self] in self?.received($0) }
        let process = Process()
        process.executableURL = executable
        let launch = HelperLaunch(broker: broker, token: token, hostPid: getpid(), headless: true)
        process.arguments = launch.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { $1 }
        do { try process.run() } catch {
            print("  cannot run \(executable.path): \(error)")
            return nil
        }
        self.process = process
        guard checkedIn.wait(timeout: .now() + 3) == .success else { return nil }
        return process.processIdentifier
    }

    func run(probes: Int) -> Result {
        var result = Result()
        guard startAndWaitForCheckIn() != nil, let process else { return result }
        result.checkedIn = true
        let surfacePort = IOSurfaceCreateMachPort(surface)
        MachChannel.send(HostMessage.surface(width: 64, height: 64), to: helperPort, port: surfacePort)
        MachChannel.deallocate(surfacePort)
        result.firstPixel = probe()
        Self.fill(surface, Self.colorB)
        result.secondPixel = probe()
        for _ in 0..<probes {
            let start = uptimeNanoseconds()
            guard probe() != nil else { break }
            result.rtts.append(Double(uptimeNanoseconds() - start) / 1000)
        }
        MachChannel.send(HostMessage.quit, to: helperPort)
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        result.exitedOnQuit = !process.isRunning
        if process.isRunning { process.terminate() }
        return result
    }

    private func probe() -> UInt32? {
        guard MachChannel.send(HostMessage.probe(x: 5, y: 5, sentNs: uptimeNanoseconds()), to: helperPort) == KERN_SUCCESS,
              answered.wait(timeout: .now() + 1) == .success else { return nil }
        return queue.sync { lastPixel }
    }

    private func received(_ received: MachReceived) {
        guard case .message(let data, let port) = received, let message = try? WireCoding.decode(HelperMessage.self, from: data) else { return }
        switch message {
        case .checkIn(let token, _) where token == self.token && helperPort == MACH_PORT_NULL:
            helperPort = port
            checkedIn.signal()
        case .probeResult(let pixel, _, _):
            MachChannel.deallocate(port)
            lastPixel = pixel
            answered.signal()
        default:
            MachChannel.deallocate(port)
        }
    }
}
