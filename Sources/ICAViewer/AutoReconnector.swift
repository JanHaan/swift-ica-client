import AppKit
import ICAKit

/// Automatic reconnect after session reliability gave up (docs/90 §9.6, D86): the same store relaunch as the
/// manual Reconnect panel (D18, docs/20 §3.12.11), started by itself. The schedule is `AutoReconnect.Plan` (ICAKit,
/// unit-tested); this class runs it with timers and the network path, shows its progress on the dimmed windows, and
/// swaps the old windows for the new connection's per app as they come back.
///
/// One job per session (`AutoReconnect.Registry`): a session with several apps (docs/55) is one connection, so one
/// relaunch brings all of them back. The old controller keeps its dimmed windows (and so its Dock helpers, docs/99)
/// until the new connection shows each app again; the helper of an app carries over to the new connection
/// (`HelperManager.replace`). Main thread only, like SessionController.
final class AutoReconnector {
    final class Job {
        let key: String
        let resource: StoreClient.Resource
        let old: SessionController
        var plan: AutoReconnect.Plan
        var timer: Timer?
        /// The relaunch's connection (attempt running, or it showed the session and the old windows are going).
        weak var current: SessionController?
        /// Increases with each attempt; results of an earlier attempt are ignored.
        var serial = 0
        /// The new connection showed an app of the session: the old windows are being replaced.
        var connected = false
        var over = false

        init(key: String, resource: StoreClient.Resource, old: SessionController, plan: AutoReconnect.Plan) {
            self.key = key
            self.resource = resource
            self.old = old
            self.plan = plan
        }
    }

    /// One relaunch, handed through `AppDelegate.launch` (also through its early-drop relaunches).
    final class Attempt {
        weak var job: Job?
        let serial: Int
        init(job: Job, serial: Int) {
            self.job = job
            self.serial = serial
        }
        /// Still the job's current attempt.
        var live: Bool { job.map { !$0.over && $0.serial == serial } ?? false }
    }

    enum Begin {
        /// The old controller stays (ended, windows dimmed) until the job is over.
        case tookOver
        /// It was a relaunch's own connection, or a second connection of a session already being reconnected:
        /// its windows are gone, it is no session of ours any more.
        case absorbed
        /// No automatic reconnect: the manual panel as before.
        case declined
    }

    /// True while the network path is satisfied.
    var online: () -> Bool = { true }
    /// A launch is running (only one at a time).
    var busy: () -> Bool = { false }
    /// The app is quitting.
    var quitting: () -> Bool = { false }
    /// Another open connection of ours with this SessionsharingKey (it holds the session again).
    var openSession: (_ sharingKey: String?, _ except: SessionController?) -> SessionController? = { _, _ in nil }
    /// Relaunch the job's resource through the store, carrying the attempt.
    var launch: (_ resource: StoreClient.Resource, _ attempt: Attempt) -> Void = { _, _ in }
    /// The old controller was replaced (its windows are gone): forget it.
    var replaced: (_ old: SessionController) -> Void = { _ in }

    private var jobs: [Job] = []
    private var registry = AutoReconnect.Registry()

    /// Time after the first app is back until the old windows of apps that did not come back go.
    static let swapGrace: TimeInterval = 10
    /// A new connection that reached the seamless channel but shows no app window counts as back after this long.
    static let windowlessCheck: TimeInterval = 30

    var isActive: Bool { !jobs.isEmpty }

    /// Session reliability gave up on `c`; `skip` is nil when the rules allow an automatic reconnect.
    func begin(_ c: SessionController, resource: StoreClient.Resource, giveUp: CGPTransport.GiveUp, skip: AutoReconnect.Skip?) -> Begin {
        if let job = jobs.first(where: { $0.current === c }) {
            if job.connected {
                // The new connection dropped after it had shown the session: the old windows go now; the new
                // connection gets a job of its own below.
                finish(job, "the new connection dropped as well")
            } else {
                vlog("auto reconnect: \(logName(job.old.name)): the relaunch's connection dropped before the session came back")
                c.finishReplaced()
                failed(Attempt(job: job, serial: job.serial), "its connection dropped", toPanel: false)
                return .absorbed
            }
        }
        if let skip {
            vlog("auto reconnect: \(logName(c.name)): not started (\(skip.rawValue)); Reconnect panel")
            return .declined
        }
        let key = AutoReconnect.sessionKey(sharingKey: c.shareKey.sharingKey, connection: "\(ObjectIdentifier(c).hashValue)")
        guard registry.claim(key) else {
            vlog("auto reconnect: \(logName(c.name)): this session is already being reconnected; no second relaunch")
            c.finishReplaced()
            return .absorbed
        }
        let job = Job(key: key, resource: resource, old: c,
                      plan: AutoReconnect.Plan(start: Date(), notBefore: giveUp.relaunchNotBefore))
        jobs.append(job)
        vlog("auto reconnect: \(logName(c.name)) (apps: \(c.appNames.map(logName).joined(separator: ", "))): started after "
             + "\"\(giveUp.message)\"; budget \(Int(AutoReconnect.Plan.budget)) s, up to \(AutoReconnect.Plan.maxAttempts) relaunches"
             + (giveUp.relaunchNotBefore.map { ", not before +\(max(0, Int($0.timeIntervalSinceNow))) s (server hold)" } ?? ""))
        tick(job)
        return .tookOver
    }

    /// The network path changed, or something else may unblock a job.
    func tickAll() {
        for job in jobs { tick(job) }
    }

    private func tick(_ job: Job) {
        guard !job.over else { return }
        job.timer?.invalidate()
        job.timer = nil
        if quitting() { return }
        var plan = job.plan
        let other = openSession(job.old.shareKey.sharingKey, job.current)
        let step = plan.step(now: Date(), online: online(), alreadyOpen: other != nil)
        if case .attempt = step, busy() {
            // Another launch runs: try again shortly, without counting an attempt.
            return schedule(job, after: 1)
        }
        job.plan = plan
        let name = job.old.name
        switch step {
        case .wait(let until, let why):
            let text: (TimeInterval) -> String
            switch why {
            case .serverHold:
                text = { loc("Connection lost. Reconnecting automatically in \(Self.clock($0))…",
                             "Verbindung verloren. Automatisch neu verbinden in \(Self.clock($0))…") }
            case .backoff:
                text = { loc("Reconnecting did not work. Next try in \(Self.clock($0))…",
                             "Neu verbinden hat nicht geklappt. Nächster Versuch in \(Self.clock($0))…") }
            case .networkSettle:
                text = { _ in loc("The network is back. Reconnecting…", "Das Netzwerk ist wieder da. Neu verbinden…") }
            }
            show(job, reconnectNow: why != .serverHold) { text(until.timeIntervalSinceNow) }
            schedule(job, at: until)
        case .waitForNetwork(let until):
            vlog("auto reconnect: \(logName(name)): offline; waiting for the network")
            show(job, reconnectNow: false) {
                loc("No network. Waiting for it (\(Self.clock(until.timeIntervalSinceNow)) left)…",
                    "Kein Netzwerk. Warten darauf (noch \(Self.clock(until.timeIntervalSinceNow)))…")
            }
            schedule(job, at: until)
        case .attempt(let n, let total):
            job.serial += 1
            vlog("auto reconnect: \(logName(name)): relaunch \(n)/\(total) through the store")
            show(job, reconnectNow: false) {
                loc("Reconnecting automatically (try \(n) of \(total))…", "Automatisch neu verbinden (Versuch \(n) von \(total))…")
            }
            launch(job.resource, Attempt(job: job, serial: job.serial))
        case .inProgress:
            break
        case .alreadyOpen:
            finish(job, "another connection of ours holds the session again")
        case .giveUp(let why):
            let reason: String
            switch why {
            case .attempts: reason = "every relaunch failed"
            case .budget(let offline): reason = offline ? "still offline after \(Int(AutoReconnect.Plan.budget)) s" : "time budget used up"
            }
            toPanel(job, "gave up (\(reason))")
        }
    }

    /// `reconnectNow`: offer "Reconnect Now" (only during a pause the user may skip, never during the server's hold).
    private func show(_ job: Job, reconnectNow: Bool, _ status: @escaping () -> String) {
        job.old.showAutoReconnect(status: status, reconnectNow: reconnectNow ? { [weak self, weak job] in
            guard let self, let job, !job.over else { return }
            vlog("auto reconnect: \(logName(job.old.name)): Reconnect Now chosen")
            job.plan.skipPause(now: Date())
            self.tick(job)
        } : nil, close: { [weak self, weak job] in
            guard let self, let job else { return }
            self.cancel(job)
        })
    }

    private func schedule(_ job: Job, at date: Date) { schedule(job, after: max(0.2, date.timeIntervalSinceNow)) }

    private func schedule(_ job: Job, after seconds: TimeInterval) {
        job.timer?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self, weak job] _ in
            guard let self, let job else { return }
            self.tick(job)
        }
        RunLoop.main.add(t, forMode: .common)
        job.timer = t
    }

    // MARK: Results of an attempt (AppDelegate.launch)

    /// The relaunch opened its connection.
    func created(_ attempt: Attempt, _ controller: SessionController) {
        guard attempt.live, let job = attempt.job else { return }
        job.current = controller
        controller.inherit(from: job.old)
        if HelperManager.enabled { HelperManager.shared.replace(job.old, with: controller) }
        controller.onAppWindowAppeared = { [weak self, weak job] c, appKey in
            guard let self, let job else { return }
            self.appeared(job, c, appKey: appKey)
        }
        checkWindowless(job, controller, after: Self.windowlessCheck)
    }

    /// A new connection that reached the seamless channel but shows no app window yet (D18's symptom): the session is
    /// back all the same (the launcher shows it as parked), so the old windows go.
    private func checkWindowless(_ job: Job, _ controller: SessionController, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak job, weak controller] in
            guard let self, let job, let controller, !job.over, !job.connected, job.current === controller, !controller.ended else { return }
            if controller.reachedSeamless {
                self.finish(job, "the new connection is up without app windows (parked)")
            } else {
                self.checkWindowless(job, controller, after: 15)
            }
        }
    }

    private func appeared(_ job: Job, _ controller: SessionController, appKey: String) {
        guard !job.over, job.current === controller else { return }
        if !job.connected {
            job.connected = true
            vlog("auto reconnect: \(logName(job.old.name)): the session is back (attempt \(job.serial))")
            job.old.hideReconnectHUD()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.swapGrace) { [weak self, weak job] in
                guard let self, let job, !job.over else { return }
                self.finish(job, "\(Int(Self.swapGrace)) s after the first app came back")
            }
        }
        job.old.dropWindows(appKey: appKey)
        if job.old.appWindowKeys.isEmpty { finish(job, "every app is back") }
    }

    /// The attempt failed. `toPanel`: no point in retrying (sign-in cancelled, launch refused): the manual panel.
    func failed(_ attempt: Attempt, _ reason: String, toPanel: Bool) {
        guard attempt.live, let job = attempt.job else { return }
        if job.connected {
            // The new connection ended after it had shown the session: its own end handling applies.
            return finish(job, "the new connection ended (\(reason))")
        }
        vlog("auto reconnect: \(logName(job.old.name)): attempt \(job.serial) failed: \(reason)")
        if let current = job.current, HelperManager.enabled { HelperManager.shared.replacementEnded(current) }
        job.current = nil
        if toPanel { return self.toPanel(job, "stopped (\(reason))") }
        job.plan.attemptFailed(now: Date(), online: online())
        tick(job)
    }

    /// The launch found the session held by another connection of ours (session sharing): nothing to relaunch.
    func alreadyOpen(_ attempt: Attempt) {
        guard attempt.live, let job = attempt.job else { return }
        finish(job, "another connection of ours holds the session")
    }

    /// The user's Close (panel, helper close button or Cmd-Q): stop, close a relaunch still connecting, close the
    /// old windows.
    private func cancel(_ job: Job) {
        guard !job.over else { return }
        if job.connected { return finish(job, "closed while the windows were being replaced") }
        vlog("auto reconnect: \(logName(job.old.name)): closed by the user")
        let current = job.current
        end(job)
        if let current, !current.ended {
            let session = current.session
            Task { await session.close() }
        }
        job.old.closeReplaced()
    }

    // MARK: End of a job

    private func end(_ job: Job) {
        job.over = true
        job.timer?.invalidate()
        job.timer = nil
        registry.release(job.key)
        jobs.removeAll { $0 === job }
        if let current = job.current, HelperManager.enabled { HelperManager.shared.replacementEnded(current) }
    }

    /// The session is back (or held by another connection of ours): the old windows go.
    private func finish(_ job: Job, _ reason: String) {
        guard !job.over else { return }
        vlog("auto reconnect: \(logName(job.old.name)): done (\(reason)); the old windows go")
        end(job)
        job.old.finishReplaced()
        replaced(job.old)
    }

    /// Into the manual Reconnect panel, as without the setting.
    private func toPanel(_ job: Job, _ reason: String) {
        guard !job.over else { return }
        vlog("auto reconnect: \(logName(job.old.name)): \(reason); Reconnect panel")
        end(job)
        job.old.showManualReconnect(note: loc("Automatic reconnect did not succeed.", "Automatisches Neuverbinden hat nicht geklappt."))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
