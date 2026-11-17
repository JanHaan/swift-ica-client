import Foundation
import ICAKit

/// `icactl signout [--verify]` (security review L-04): ends the store and gateway sessions at the servers as the
/// viewer's Sign Out does (`AccountSignOut`), deletes the saved jar, and with `--verify` replays the old cookies in a
/// fresh client: the store must ask for a logon again, which shows that the servers ended the session (a merely
/// forgotten cookie would still work). Prints step names and statuses only, never cookie values.
func runSignOut(_ args: [String]) async {
    let verify = args.contains("--verify")
    let store = storeClient()
    guard !http.cookieNames.isEmpty else { fail("not signed in (no cookies in \(cookiePath)); run `icactl login` first") }
    let before = (try? await store.resources()).map { "\($0.count) resources" } ?? "resource list not readable"
    print("before: \(before)")
    let old = http.cookieRecords("NSC_AAAC") + (http.cookieNames.filter { $0 != "NSC_AAAC" }.flatMap { http.cookieRecords($0) })
    let steps = await AccountSignOut.run(http: http, storeBase: store.base, gateway: storeFront == nil ? gateway : nil,
                                         cookieFile: cookiePath)
    for step in steps { print("sign-out: \(step)") }
    print("cookies left: \(http.cookieNames.count); jar file present: \(FileManager.default.fileExists(atPath: cookiePath) ? "yes" : "no")")
    guard verify else { return }
    let replay = HTTPClient()
    replay.trace = { _ in }
    for cookie in old { replay.setCookie(cookie) }
    let probe = storeFront == nil ? StoreClient(http: replay, base: store.base) : StoreClient(http: replay, directBase: storeFront!)
    do {
        let list = try await probe.resources()
        print("RESULT FAIL: the old cookies still list \(list.count) resources (session not ended at the server)")
        exit(1)
    } catch {
        print("RESULT PASS: the old cookies are refused (\(error))")
    }
}
