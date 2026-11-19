import AppKit
import ICAKit

/// Links opened in a remote app open in the Mac's default browser (host-to-client URL redirection, docs/56). The
/// server's policy decides whether the session hands links over at all; every link it does hand over passes the
/// security rule of docs/56 §5 first, then the reachability check (§4). A link that fails either stays in the session,
/// which opens it in the server's browser. No prompt, no setting (`ICA_URL_REDIRECT=0` turns it off for tests).
/// Main thread.
final class LinkOpener {
    static let shared = LinkOpener()

    /// One limit for the whole app, so several sessions cannot add up (§5.3).
    private var limiter = URLRedirectLimiter()
    private let start = Date()
    private let probeQueue = DispatchQueue(label: "ICAViewer.link-probe")

    static var enabled: Bool {
        let value = ProcessInfo.processInfo.environment["ICA_URL_REDIRECT"]?.lowercased()
        return !["0", "off", "no"].contains(value ?? "")
    }

    /// Decides one link; `reply(opened)` is called once, on main.
    func open(_ raw: String, from session: String, reply: @escaping (Bool) -> Void) {
        let url: URL
        switch URLRedirectFilter.check(raw) {
        case .refused(let why):
            vlog("links: \(URLRedirectFilter.logSummary(raw: raw)) from \(logName(session)) refused (\(why)); the session opens it")
            return reply(false)
        case .open(let u):
            url = u
        }
        let summary = URLRedirectFilter.logSummary(url)
        guard limiter.allow(at: Date().timeIntervalSince(start)) else {
            if limiter.dropped == 1 {
                vlog("links: more than \(limiter.limit) links in \(Int(limiter.window)) s; further links stay in the session until it calms down")
            }
            return reply(false)
        }
        let dropped = limiter.takeDropped()
        if dropped > 0 { vlog("links: \(dropped) links were left to the session by the rate limit") }
        URLRedirectProbe.check(url, queue: probeQueue) { reachable in
            DispatchQueue.main.async {
                guard reachable else {
                    vlog("links: \(summary) from \(logName(session)) is not reachable from this Mac; the session opens it")
                    return reply(false)
                }
                NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { vlog("links: the Mac could not open \(summary): \(error.localizedDescription)") }
                }
                vlog("links: \(summary) from \(logName(session)) opened in the default browser")
                reply(true)
            }
        }
    }
}
