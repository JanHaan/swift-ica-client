import Foundation
@testable import ICAKit

/// A `CGPClock` that only moves when the test says so. Two clocks as on the Mac: the uptime clock
/// (`SuspendingClock`, `DispatchTime` timers) stops during system sleep, the continuous clock
/// (`ContinuousClock`, wall timers) runs on. `advance` moves both, `sleep` only the continuous one.
/// Due timers run in due order on their queue (synchronously, from the calling thread), each with
/// the clock set to its due time. Times are kept in whole nanoseconds so sums are exact.
final class ManualCGPClock: CGPClock, @unchecked Sendable {
    private let lock = NSLock()
    private let continuousBase = ContinuousClock.now
    private let suspendingBase = SuspendingClock.now
    private let dateBase = Date()
    /// Elapsed on both clocks.
    private var awake: Int64 = 0
    /// Elapsed on the continuous clock only (system asleep).
    private var asleep: Int64 = 0
    private var timers: [Timer] = []
    private var order = 0

    final class Timer: CGPTimer, @unchecked Sendable {
        let wall: Bool
        /// On the uptime clock (`awake`) or, for a wall timer, the continuous clock (`awake + asleep`).
        var due: Int64
        let interval: Int64?
        let seq: Int
        let queue: DispatchQueue
        let work: () -> Void
        weak var clock: ManualCGPClock?
        var cancelled = false   // under the clock's lock

        init(wall: Bool, due: Int64, interval: Int64?, seq: Int, queue: DispatchQueue, work: @escaping () -> Void, clock: ManualCGPClock) {
            (self.wall, self.due, self.interval, self.seq, self.queue, self.work, self.clock) = (wall, due, interval, seq, queue, work, clock)
        }

        func cancel() { clock?.cancel(self) }
    }

    private static func ns(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1e9).rounded()) }

    func now() -> ContinuousClock.Instant { locked { continuousBase + .nanoseconds(awake + asleep) } }
    func uptime() -> SuspendingClock.Instant { locked { suspendingBase + .nanoseconds(awake) } }
    func date() -> Date { locked { dateBase.addingTimeInterval(Double(awake + asleep) / 1e9) } }

    /// Seconds on the continuous clock since the clock was made.
    var elapsed: TimeInterval { locked { Double(awake + asleep) / 1e9 } }
    /// Timers not yet run or cancelled.
    var pending: Int { locked { timers.count } }

    @discardableResult
    func schedule(after delay: TimeInterval, wall: Bool, on queue: DispatchQueue, _ work: @escaping () -> Void) -> CGPTimer {
        locked {
            order += 1
            let due = (wall ? awake + asleep : awake) + max(0, Self.ns(delay))
            let timer = Timer(wall: wall, due: due, interval: nil, seq: order, queue: queue, work: work, clock: self)
            timers.append(timer)
            return timer
        }
    }

    func scheduleRepeating(every interval: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) -> CGPTimer {
        locked {
            order += 1
            let step = max(1, Self.ns(interval))
            let timer = Timer(wall: false, due: awake + step, interval: step, seq: order, queue: queue, work: work, clock: self)
            timers.append(timer)
            return timer
        }
    }

    private func cancel(_ timer: Timer) {
        locked {
            timer.cancelled = true
            timers.removeAll { $0 === timer }
        }
    }

    /// Time passes with the system awake: both clocks move and every timer due on the way runs.
    func advance(by seconds: TimeInterval) {
        let target = locked { awake + Self.ns(seconds) }
        while let timer = nextDue(awakeTarget: target) { fire(timer) }
        locked { awake = max(awake, target) }
    }

    /// System sleep: only the continuous clock moves. Wall timers that came due run at wake.
    func sleep(for seconds: TimeInterval) {
        locked { asleep += Self.ns(seconds) }
        while let timer = nextDue(awakeTarget: locked { awake }) { fire(timer) }
    }

    /// The earliest timer due by `awakeTarget`; moves the clocks to its due time and takes it off
    /// the list (a repeating one goes back with its next due time).
    private func nextDue(awakeTarget: Int64) -> Timer? {
        locked {
            func remaining(_ t: Timer) -> Int64 { t.due - (t.wall ? awake + asleep : awake) }
            guard let next = timers.min(by: { (remaining($0), $0.seq) < (remaining($1), $1.seq) }),
                  awake + max(0, remaining(next)) <= awakeTarget else { return nil }
            awake += max(0, remaining(next))
            if let interval = next.interval {
                next.due = awake + interval
                order += 1
            } else {
                timers.removeAll { $0 === next }
            }
            return next
        }
    }

    private func fire(_ timer: Timer) {
        // On the timer's queue, so a cancel there either precedes the run (and wins) or follows it.
        timer.queue.sync {
            guard !locked({ timer.cancelled }) else { return }
            timer.work()
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Wakes `eventually` callers when test state may have changed (client event, server callback).
/// Waiters also recheck every 50 ms, so a missed notification only costs latency.
final class TestSignal: @unchecked Sendable {
    static let shared = TestSignal()
    private let lock = NSLock()
    private var generation = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    func notify() {
        lock.lock()
        generation += 1
        let pending = waiters
        waiters = [:]
        lock.unlock()
        pending.values.forEach { $0.resume() }
    }

    var current: Int { lock.lock(); defer { lock.unlock() }; return generation }

    /// Returns after the next notification following `seen`, or after `limit`.
    func wait(after seen: Int, limit: TimeInterval) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if generation != seen {
                lock.unlock()
                return continuation.resume()
            }
            nextID += 1
            let id = nextID
            waiters[id] = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [self] in
                lock.lock()
                let waiter = waiters.removeValue(forKey: id)
                lock.unlock()
                waiter?.resume()
            }
        }
    }
}

/// Waits for `condition`; `timeout` (real seconds) only guards against a hang and is never what a
/// test measures.
func eventually(_ timeout: TimeInterval = 60, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while true {
        let seen = TestSignal.shared.current
        if condition() { return true }
        let left = end.timeIntervalSinceNow
        if left <= 0 { return false }
        await TestSignal.shared.wait(after: seen, limit: min(0.05, left))
    }
}

/// `ICA_TEST_CPU_LOAD=<threads>` (0 or unset: off): busy threads in the test process for the
/// stress runs of the CGP end-to-end tests. Started once, run until the process exits.
enum TestCPULoad {
    static let started: Void = {
        guard let n = ProcessInfo.processInfo.environment["ICA_TEST_CPU_LOAD"].flatMap(Int.init), n > 0 else { return }
        for i in 0..<n {
            let thread = Thread {
                var x: UInt64 = 0x9e37_79b9_7f4a_7c15
                while true { x = x &* 6364136223846793005 &+ 1442695040888963407; if x == 0 { print("") } }
            }
            thread.name = "cpu-load-\(i)"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }()
}
