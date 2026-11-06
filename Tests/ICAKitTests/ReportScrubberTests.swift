import CryptoKit
import Foundation
import Testing
@testable import ICAKit

/// Synthetic data only: example.com-style hosts, made-up users and resource names.
@Suite struct ReportScrubberTests {
    static let password = "S3cr3t!Pass-42"
    static let totpSecret = "JBSWY3DPEHPK3PXP"

    static func context() -> ReportScrubber.Context {
        var c = ReportScrubber.Context()
        c.hosts = ["gateway.example-corp.test.com"]
        c.userNames = ["CORPX\\jdoe", "emuster", "Erika Muster"]
        c.domains = ["CORPX"]
        c.computerNames = ["Erika’s MacBook Pro", "Erikas-MacBook-Pro"]
        c.resourceNames = ["Calculator ABC", "Paint ABC"]
        c.secretValues = [password, totpSecret]
        c.censorWords = [.init(word: "Acmecorp", with: "Example")]
        return c
    }

    static let scrubber = ReportScrubber(context())

    func scrub(_ text: String, _ scrubber: ReportScrubber = ReportScrubberTests.scrubber) -> String { scrubber.scrub(text) }

    // MARK: Secrets

    @Test func knownSecretValuesNeverAppear() {
        for line in ["typed \(Self.password) by mistake", "CITRIX_PASSWORD=\(Self.password)",
                     "secret \(Self.totpSecret) end", "url p=\(Self.password.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)",
                     "lower jbswy3dpehpk3pxp is not the literal but \("JBSW Y3DP EHPK 3PXP".replacingOccurrences(of: " ", with: ""))"] {
            let out = scrub(line)
            #expect(!out.contains(Self.password), "\(out)")
            #expect(!out.contains(Self.totpSecret), "\(out)")
            #expect(!out.contains("S3cr3t"), "\(out)")
        }
    }

    @Test func secretFieldsAreRedactedInEveryNotation() {
        let cases: [(String, String)] = [
            ("password=hunter2", "password=<redacted>"),
            ("CITRIX_PASSWORD=hunter2 next", "CITRIX_PASSWORD=<redacted> next"),
            ("passwd: hunter2", "passwd: <redacted>"),
            ("{\"password\":\"hunter 2\",\"user\":\"x\"}", "{\"password\":\"<redacted>\",\"user\":\"x\"}"),
            ("'secret': 'abc def'", "'secret': '<redacted>'"),
            ("CsrfToken=0a1b2c3d", "CsrfToken=<redacted>"),
            ("Csrf-Token: zz", "Csrf-Token: <redacted>"),
            ("LogonTicket=ABCDEF0123", "LogonTicket=<redacted>"),
            ("ReconnectTicket: 77", "ReconnectTicket: <redacted>"),
            ("LaunchReference=QWERTY", "LaunchReference=<redacted>"),
            ("sessionId=s-1234 deviceId: d-99", "sessionId=<redacted> deviceId: <redacted>"),
            ("totp=123", "totp=<redacted>"),
            ("api_key=k", "api_key=<redacted>"),
            ("NSC_AAAC=xyz", "NSC_AAAC=<redacted>"),
            ("settings: password: hunter2", "settings: password: <redacted>"),
            ("x=passwd=abc", "x=passwd=<redacted>"),
            ("password: a:b:c", "password: <redacted>"),
        ]
        for (input, expected) in cases { #expect(scrub(input) == expected, "\(input)") }
    }

    @Test func xmlAndAuthorizationSecrets() {
        #expect(scrub("<Password>xyz</Password> <LogonTicket>AAAA</LogonTicket>")
                == "<Password><redacted></Password> <LogonTicket><redacted></LogonTicket>")
        #expect(scrub("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.abc123") == "Authorization: Bearer <redacted>")
        #expect(scrub("Basic dXNlcjpwYXNzd29yZA==") == "Basic <redacted>")
        #expect(scrub("basic functionality works") == "basic functionality works")
    }

    @Test func descriptiveValuesStayReadable() {
        for line in ["login: saved username: yes, password present: yes, secret present: no",
                     "login: form 1: login:username,passwd:password,passcode:passcode",
                     "remembered login: password unchanged, secret stored, password protected: yes",
                     "→ CGP bind request (ticket 120 chars)", "token=…"] {
            #expect(scrub(line) == line, "\(line)")
        }
    }

    @Test func cookiesKeepNamesButLoseValues() {
        #expect(scrub("Cookie: NSC_AAAC=abc123def; CsrfToken=0123") == "Cookie: NSC_AAAC=<redacted>; CsrfToken=<redacted>")
        #expect(scrub("Set-Cookie: CtxsAuthId=Q2xv; path=/; HttpOnly") == "Set-Cookie: CtxsAuthId=<redacted>; path=<redacted>; HttpOnly")
        #expect(scrub("http ← 200 1234B set-cookie: NSC_AAAC,CsrfToken") == "http ← 200 1234B set-cookie: NSC_AAAC,CsrfToken")
        #expect(scrub("cookie=raw-value-1") == "cookie=<redacted>")
    }

    @Test func ticketsAndOneTimeCodes() {
        #expect(scrub("Address=;40;STA2C1F3D4E;8F2A9C0B1D3E4F5A6B7C8D9E") == "Address=;40;<sta-ticket>")
        #expect(scrub("passcode 123456 accepted") == "passcode <code> accepted")
        #expect(scrub("one-time code 87654321") == "one-time code <code>")
        #expect(scrub("OTP: 87654321") == "OTP: <redacted>")   // a secret field already
        #expect(scrub("verification code is 135792") == "verification code is <code>")
        #expect(scrub("exit code 1, status code 200") == "exit code 1, status code 200")
        #expect(scrub("base32 GEZDGNBVGY3TQOJQGEZDGNBV end") == "base32 <redacted> end")
    }

    @Test func finalPassCatchesSecretsEvenAfterRewrites() {
        // The value only becomes a plain `name=value` after the query rule rewrote the URL around it.
        let out = scrub("https://gateway.example-corp.test.com/x?a=1&password=pw9 password=pw8")
        #expect(!out.contains("pw9") && !out.contains("pw8"), "\(out)")
    }

    // MARK: Hosts and addresses

    @Test func gatewayAndItsDomain() {
        #expect(scrub("http → GET gateway.example-corp.test.com/Citrix/Store/resources?token=…")
                == "http → GET <gateway>/Citrix/Store/resources?token=…")
        #expect(scrub("gateway: GATEWAY.example-corp.test.com.") == "gateway: <gateway>.")
        #expect(scrub("storefront.example-corp.test.com and test.com") == "<gateway-domain> and <gateway-domain>")
        #expect(ReportScrubber.baseDomain("gw.example.co.uk") == "example.co.uk")
        #expect(ReportScrubber.baseDomain("gw.example.com") == "example.com")
        #expect(ReportScrubber.baseDomain("10.1.2.3") == nil)
    }

    @Test func otherHosts() {
        #expect(scrub("TLS connected to srv-ctx01:443") == "TLS connected to <host>:443")
        #expect(scrub("resume attempt 2: connecting to vda07.corp.internal:2598") == "resume attempt 2: connecting to <host>:2598")
        #expect(scrub("see intranet.othercorp.de now") == "see <host> now")
        #expect(scrub("https://portal.some-org.net/a") == "https://<host>/a")
        #expect(scrub("host files.internal.lan") == "host <host>")
    }

    @Test func notHosts() {
        for line in ["error ICAKit.HTTPClient.Failure.status(403) in Info.plist, README.md, main.swift",
                     "com.apple.preference.displays", "see https://github.com/JanHaan/swift-ica-client and gateway.example.com",
                     "macOS 15.1 (24B83) on Mac15,8", "cdm.enabled", "localhost:8080", "e.g. this, i.e. that",
                     "capture-thinwire.h264 and report.final.pdf"] {
            #expect(scrub(line) == line, "\(line)")
        }
    }

    @Test func ipAddresses() {
        #expect(scrub("TLS connected to 10.20.30.40:2598") == "TLS connected to <ipv4>:2598")
        #expect(scrub("from 192.168.1.255, loopback 127.0.0.1, any 0.0.0.0") == "from <ipv4>, loopback 127.0.0.1, any 0.0.0.0")
        #expect(scrub("not an address 300.1.2.3 or 1.2.3") == "not an address 300.1.2.3 or 1.2.3")
        #expect(scrub("fe80::1%en0 and ::1 and 2001:db8::8a2e:370:7334") == "<ipv6> and ::1 and <ipv6>")
        #expect(scrub("mapped ::ffff:10.0.0.1 end") == "mapped <ipv6> end")
        #expect(scrub("[2001:db8::1]:443") == "[<ipv6>]:443")
        #expect(scrub("at 12:34:56 and Cmd-C: copy") == "at 12:34:56 and Cmd-C: copy")
        #expect(scrub("mac aa:bb:cc:dd:ee:ff or AA-BB-CC-DD-EE-FF") == "mac <mac> or <mac>")
        #expect(scrub("fp AA:BB:CC:DD:EE:FF:00:11:22:33") == "fp <fingerprint>")
    }

    // MARK: Identifiers

    @Test func identifiers() {
        #expect(scrub("session 3F2504E0-4F89-11D3-9A0C-0305E82C3301 end") == "session <id> end")
        #expect(scrub("{3F2504E0-4F89-11D3-9A0C-0305E82C3301}") == "<id>")
        #expect(scrub("hex 0123456789abcdef0123456789abcdef") == "hex <id>")
        #expect(scrub("raw a8Fk2LmQ9zXw4Rt7Yp1Bn6Vc3Ds5") == "raw <token>")
        #expect(scrub("b64 q83vEjRWeJA+/s7A8D9xYz0Kp=") == "b64 <token>")
        #expect(scrub("upper 8F2A9C0B1D3E4F5A6B7C8D9QWZ") == "upper <token>")
        #expect(scrub("window 1a2b and short abc123") == "window 1a2b and short abc123")
    }

    @Test func pathsAndNamesAreNotTokens() {
        for line in ["~/Library/Logs/ICAViewer/ICAViewer.log", "Sources/ICAViewer/FeedbackWindow.swift",
                     "Fixtures/thinwire-capture-01.bin", "/Library/Caches/ICAViewer/PrintJobs/job-12",
                     "ICAVIEWER_SELFTEST_MOVE_DX", "capture-2024-01-05-103015", "ThinwireReplayTests"] {
            #expect(scrub(line) == line, "\(line)")
        }
    }

    // MARK: Paths

    @Test func homeAndWindowsPaths() {
        #expect(scrub("/Users/emuster/Library/Logs/x.log") == "~/Library/Logs/x.log")
        #expect(scrub("/Users/someone_else/Desktop") == "~/Desktop")
        #expect(scrub("file:///Users/emuster/Desktop/a") == "~/Desktop/a")
        #expect(scrub("/Users/Shared/ICA") == "/Users/Shared/ICA")
        #expect(scrub("/home/bob/.config") == "~/.config")
        #expect(scrub("file at /Volumes/Erika Disk/Docs") == "file at /Volumes/<volume>/Docs")
        #expect(scrub("C:\\Users\\mmuster\\AppData\\Local\\Temp") == "C:\\Users\\<user>\\AppData\\Local\\Temp")
        #expect(scrub("c:/users/mmuster/x") == "c:/users/<user>/x")
        #expect(scrub("C:\\Documents and Settings\\mmuster\\x") == "C:\\Documents and Settings\\<user>\\x")
        #expect(scrub("open \\\\fileserver01\\share\\a") == "open \\\\<server>\\share\\a")
    }

    // MARK: People

    @Test func usersDomainsComputersAndEmails() {
        #expect(scrub("user CORPX\\jdoe signed in as jdoe@example-corp.test.com, Erika Muster")
                == "user <user> signed in as <email>, <user>")
        #expect(scrub("domain CORPX, user JDOE") == "domain <domain>, user <user>")
        #expect(scrub("on Erika’s MacBook Pro / Erikas-MacBook-Pro") == "on <computer> / <computer>")
        #expect(scrub("mail anyone@mail.example.org") == "mail <email>")
        #expect(scrub("jdoeX stays, as does xemuster") == "jdoeX stays, as does xemuster")
        #expect(scrub("webcam: saved (on, camera \"Erika’s iPhone Camera\")") == "webcam: saved (on, camera \"<camera>\")")
    }

    @Test func placeholdersAreNeverRewritten() {
        var c = ReportScrubber.Context()
        c.userNames = ["user", "redacted", "host"]
        c.hosts = ["gateway"]
        let s = ReportScrubber(c)
        #expect(s.scrub("user at 10.0.0.9 and password=x") == "<user> at <ipv4> and password=<redacted>")
        #expect(s.scrub("<user> stays") == "<user> stays")
        // Scrubbing a scrubbed text changes nothing.
        let once = ReportScrubberTests.scrubber.scrub("CORPX\\jdoe at 10.0.0.9 on gateway.example-corp.test.com, password=x")
        #expect(ReportScrubberTests.scrubber.scrub(once) == once)
    }

    @Test func privateUseInputCannotForgePlaceholders() {
        #expect(scrub("a\u{E001}b") == "ab")
    }

    // MARK: Resource names

    @Test func resourceNamesBecomePseudonyms() {
        let log = """
        session Calculator ABC: 1 screen(s)
        TWI app added: app:Notepad XYZ "Notepad XYZ"
        launcher: Calculator not launched
        automated launch of "Mailer QRS" refused
        """
        let s = ReportScrubber(Self.context(), learningFrom: [log])
        #expect(s.names == ["Calculator ABC", "Mailer QRS", "Notepad XYZ", "Paint ABC"])
        #expect(s.scrub(log) == """
        session App 1: 1 screen(s)
        TWI app added: app:App 3 "App 3"
        launcher: App 1 not launched
        automated launch of "App 2" refused
        """)
        #expect(s.scrub("paint abc crashed") == "App 4 crashed")
        // The same name gets the same number in every part of a report.
        #expect(s.scrub("Calculator ABC") == s.scrub("calculator abc"))
    }

    @Test func includedResourceNamesLoseTheirTag() {
        var c = Self.context()
        c.includeResourceNames = true
        let s = ReportScrubber(c, learningFrom: ["TWI app added: app:Notepad XYZ \"Notepad XYZ\""])
        #expect(s.scrub("session Calculator ABC; Notepad XYZ; Calculator") == "session Calculator; Notepad; Calculator")
    }

    @Test func learnedNames() {
        #expect(ReportScrubber.learnedNames(in: "TWI app added: aumid:Some.App_1!App \"Some App\"") == ["Some App", "aumid:Some.App_1!App"])
        #expect(ReportScrubber.learnedNames(in: "TWI app added: app:Calc Plus \"Calc Plus\"") == ["Calc Plus", "Calc Plus"])
        #expect(ReportScrubber.learnedNames(in: "nothing here").isEmpty)
    }

    @Test func censorWords() {
        #expect(scrub("the ACMECORP environment") == "the Example environment")
    }

    // MARK: Whole log

    @Test func realisticLogKeepsDiagnosticsAndDropsEverythingPersonal() {
        let log = """
           0.12 gateway: gateway.example-corp.test.com; logon: login window
           0.80 http → POST gateway.example-corp.test.com/nf/auth/doAuthentication.do
           0.95 http ← 200 512B set-cookie: NSC_AAAC,NSC_DLGE
           3.10 login: form 2: passcode:passcode
           4.00 TLS connected to 10.1.2.3:443
           4.02 → CGP bind request (ticket 120 chars)
           5.30 session Paint ABC: 2 screen(s), display 3024x1964
           6.00 drive mapping: M: = /Users/emuster/ICA Share
           7.00 print: job 1 from C:\\Users\\jdoe\\Documents\\a.pdf (session job 3): 12345 B, 1 page(s)
           8.00 resource list failed (status 401, ticket=AbC1dEf2GhI3jKl4MnO5pQr6); logging on
        """
        let out = Self.scrubber.scrubLines(log, chunkLines: 3)
        #expect(out == Self.scrubber.scrub(log))
        for gone in ["example-corp", "10.1.2.3", "emuster", "jdoe", "Paint", "AbC1dEf2"] {
            #expect(!out.contains(gone), "\(gone) in \(out)")
        }
        for kept in ["login window", "set-cookie: NSC_AAAC,NSC_DLGE", "passcode:passcode", "ticket 120 chars",
                     "2 screen(s), display 3024x1964", "12345 B, 1 page(s)", "status 401", "<gateway>/nf/auth/doAuthentication.do"] {
            #expect(out.contains(kept), "\(kept) missing in \(out)")
        }
    }

    @Test func isSecretName() {
        for name in ["password", "CITRIX_TOTP_SECRET", "CsrfToken", "x-citrix-ticket", "otp", "SessionID", "NSC_TMAS"] {
            #expect(ReportScrubber.isSecretName(name), "\(name)")
        }
        for name in ["username", "hotplug", "gateway", "resource", "login"] {
            #expect(!ReportScrubber.isSecretName(name), "\(name)")
        }
    }
}

/// Regressions from the privacy review: one test per leak class, synthetic values only.
@Suite struct ReportScrubberLeakTests {
    static func id(_ text: String, url: Bool = false) -> String {
        let b64 = Data(text.utf8).base64EncodedString()
        return url ? b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-") : b64
    }

    static func context() -> ReportScrubber.Context {
        var c = ReportScrubber.Context()
        c.hosts = ["gateway.example-corp.test.com"]
        c.resourceNames = ["Calculator ABC"]
        return c
    }

    @Test func resourceIdsInStoreURLs() {
        let known = Self.id("CVAD.Calculator ABC"), unknown = Self.id("CVAD.Mailer QRS", url: true)
        let log = """
        http → GET gateway.example-corp.test.com/Citrix/Store/Resources/LaunchIca/\(known).ica
        http → GET gateway.example-corp.test.com/Citrix/Store/Resources/GetLaunchStatus/\(unknown)
        http → GET gateway.example-corp.test.com/Citrix/Store/resources/v2/\(unknown)/launch/ica
        http → GET gateway.example-corp.test.com/Citrix/Store/Resources/Icon/\(Self.id("x.y"))?size=32
        """
        let s = ReportScrubber(Self.context(), learningFrom: [log])
        #expect(s.names == ["Calculator ABC", "Mailer QRS"])   // learned from the id itself
        let out = s.scrub(log)
        #expect(out == """
        http → GET <gateway>/Citrix/Store/Resources/LaunchIca/<resource-id>(App 1).ica
        http → GET <gateway>/Citrix/Store/Resources/GetLaunchStatus/<resource-id>(App 2)
        http → GET <gateway>/Citrix/Store/resources/v2/<resource-id>(App 2)/launch/ica
        http → GET <gateway>/Citrix/Store/Resources/Icon/<resource-id>?size=…
        """)
        // Without learning, an unknown id is still replaced.
        #expect(ReportScrubber(ReportScrubber.Context()).scrub("/Resources/LaunchIca/\(unknown).ica") == "/Resources/LaunchIca/<resource-id>.ica")
        var shown = Self.context()
        shown.includeResourceNames = true
        #expect(ReportScrubber(shown).scrub("/Resources/LaunchIca/\(known).ica") == "/Resources/LaunchIca/<resource-id>(Calculator).ica")
    }

    @Test func idSegmentsInAnyURLPath() {
        let s = ReportScrubber(Self.context())
        #expect(s.scrub("→ GET gateway.example-corp.test.com/x/AbCdEf123456ghIJ/y") == "→ GET <gateway>/x/<id>/y")
        #expect(s.scrub("https://portal.example.com/s/Zm9vYmFyYmF6cXV4/a") == "https://portal.example.com/s/<id>/a")
        #expect(s.scrub("→ POST gateway.example-corp.test.com/Citrix/Store/ExplicitAuth/doAuthentication.do")
                == "→ POST <gateway>/Citrix/Store/ExplicitAuth/doAuthentication.do")
        #expect(ReportScrubber.decodedResourceName(Self.id("CVAD.Notes Pro", url: true) + ".ica") == ["Notes Pro", "CVAD.Notes Pro"])
    }

    @Test func plainNamesFromEarlierRunsAreLearned() {
        let log = """
           2.00 session Paint XYZ closed: user
           2.05 session Paint XYZ: 1 screen(s), display 800x600
           2.10 launch: Draw Tool: no running session to share; new connection
           2.20 connection center: reconnect via resource Notes Pro
           2.30 session sharing: Word Thing could not be started in the running session (x); no second connection
           2.40 session sharing: starting Sheet One in the session of Word Thing, Mail Two over CTXCTL
           2.50 disconnect Mail Two (CGP FINISH)
           2.60 launcher: Viewer Q not launched; Mail Two is still starting
        """
        let s = ReportScrubber(Self.context(), learningFrom: [log])
        let out = s.scrub(log)
        for name in ["Paint", "Draw Tool", "Notes Pro", "Word Thing", "Sheet One", "Mail Two", "Viewer Q"] {
            #expect(!out.contains(name), "\(name) in \(out)")
        }
        #expect(out.contains("session sharing: starting App"))
        #expect(!s.names.contains("sharing"))
    }

    @Test func quotedNamesAreAlwaysHidden() {
        let log = "session «Viewer Q»: 1 screen(s)\nTWI app added: «app:Viewer Q» «Viewer Q»\nTWI window 1a added: appWindow (12 chars) rect 0,0 1x1 app «app:Viewer Q»"
        let s = ReportScrubber(Self.context(), learningFrom: [log])
        #expect(s.names == ["Calculator ABC", "Viewer Q"])
        #expect(s.scrub(log) == "session «App 2»: 1 screen(s)\nTWI app added: «app:App 2» «App 2»\nTWI window 1a added: appWindow (12 chars) rect 0,0 1x1 app «app:App 2»")
        // A quoted name the scrubber never learned (e.g. pasted into the description).
        #expect(ReportScrubber(ReportScrubber.Context()).scrub("crash in «Secret App»") == "crash in «<name>»")
    }

    @Test func driveMappingPaths() {
        let s = ReportScrubber(Self.context())
        #expect(s.scrub("cdm: OPEN Projects/Secret Plan.docx access 1 disposition 1 → ctx 3 opened")
                == "cdm: OPEN <path> access 1 disposition 1 → ctx 3 opened")
        #expect(s.scrub("cdm: CREATE Plans/x.txt mode 0x02 → ctx 4") == "cdm: CREATE <path> mode 0x02 → ctx 4")
        #expect(s.scrub("cdm: RENAME a/old name.txt → b/new name.txt") == "cdm: RENAME <path> → <path>")
        #expect(s.scrub("cdm: CLOSE ctx 3 Projects/Plan.docx: read 1 B, written 0 B") == "cdm: CLOSE ctx 3 <path>: read 1 B, written 0 B")
        #expect(s.scrub("cdm: WRITE ctx 3 Plan.docx 12 B at 0 → errno 28") == "cdm: WRITE ctx 3 <path> 12 B at 0 → errno 28")
        #expect(s.scrub("cdm: DELETE Old Stuff/a.txt") == "cdm: DELETE <path>")
        #expect(s.scrub("drive mapping: M: = /Users/someone/Private Folder (read-only)") == "drive mapping: M: = <path> (read-only)")
        for kept in ["cdm: OPEN path[24 chars #1a2b3c] access 1 disposition 1 → ctx 3 opened",
                     "cdm: CONNECT fields [0001 0002] → UTF-8, caps 0x01", "cdm: FIND_FIRST / → 3 of 3, complete",
                     "cdm: CLOSE ctx 1: unknown handle", "drive mapping: M: = path[30 chars #00ff00]"] {
            #expect(s.scrub(kept) == kept, "\(kept)")
        }
    }

    @Test func cdmPathLabelsHideNames() {
        let label = CDMPath(["Projects", "Secret Plan.docx"]).logLabel
        #expect(label.hasPrefix("path[25 chars #") && !label.contains("Secret"))
        #expect(label == CDMPath(["projects", "SECRET PLAN.docx"]).logLabel)   // case-folded, stable
        #expect(CDMPath.root.logLabel == "/")
    }

    @Test func otherServersAndAccounts() {
        let s = ReportScrubber(Self.context())
        #expect(s.scrub("open \\\\fs01 and \\\\fs02\\share") == "open \\\\<server> and \\\\<server>\\share")
        #expect(s.scrub("signed in as OTHERDOM\\mmeier") == "signed in as <domain>\\<user>")
        #expect(s.scrub("C:\\Users\\mmeier\\AppData\\Local") == "C:\\Users\\<user>\\AppData\\Local")
        #expect(s.scrub("TLS connected to vda07 and host srv-02, server ctxsrv.corp-lan")
                == "TLS connected to <host> and host <host>, server <host>")
        #expect(s.scrub("http → GET ctxgw01/Citrix") == "http → GET <host>/Citrix")
        #expect(s.scrub("↪ 302 → portal.example-corp.zz/x") == "↪ 302 → <host>/x")
        #expect(s.scrub("see https://intranet.weird/a") == "see https://<host>/a")
        #expect(s.scrub("webcam: opening \"Erika’s Camera\" (chosen in Settings)") == "webcam: opening \"<camera>\" (chosen in Settings)")
        for kept in ["TWI host init: flags 0x01, host foreground: 1a, host TRANSMIT (12 B)", "connected to <gateway>",
                     "https://github.com/JanHaan/swift-ica-client/issues", "host list echoes our own announce",
                     "server chose profile 2", "server log.txt"] {
            #expect(s.scrub(kept) == kept, "\(kept)")
        }
    }
}

/// Regressions from the second privacy review (synthetic values only).
@Suite struct ReportScrubberReviewTwoTests {
    let s = ReportScrubber(ReportScrubberLeakTests.context())

    @Test func cdmLabelsAreKeyed() {
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        let label = CDMPath.logLabel("mmeier", key: a)
        #expect(label == CDMPath.logLabel("MMEIER", key: a))       // stable under one key, case-folded
        #expect(label != CDMPath.logLabel("mmeier", key: b))       // another install: another label
        #expect(label.range(of: #"^path\[6 chars #[0-9a-f]{8}\]$"#, options: .regularExpression) != nil)
        // The unsalted FNV-1a label of the earlier version must not come back.
        var fnv: UInt32 = 0x811C_9DC5
        for byte in "mmeier".utf8 { fnv = (fnv ^ UInt32(byte)) &* 0x0100_0193 }
        #expect(!label.contains(String(format: "%06x", fnv & 0xFF_FFFF)))
    }

    @Test func driveRootIsOnlyDefaultOrCustom() {
        for kept in ["drive mapping: M: = custom folder (31 chars) (read-only)", "drive mapping: M: = default folder (40 chars)"] {
            #expect(s.scrub(kept) == kept)
        }
    }

    @Test func printSourcesAreQuotedNames() {
        let log = "print: job 1 from «Paint XYZ» (session job 3): 100 B, 1 page(s), "
        #expect(ReportScrubber(ReportScrubberLeakTests.context(), learningFrom: [log]).scrub(log)
                == "print: job 1 from «App 2» (session job 3): 100 B, 1 page(s), ")
    }

    @Test func serverAssignments() {
        #expect(s.scrub("CTXSRVR=ctxapp") == "CTXSRVR=<host>")
        #expect(s.scrub("CTXSRVR: ctxapp7") == "CTXSRVR: <host>")
        #expect(s.scrub("server = appsrv, host=farm") == "server = <host>, host=<host>")
        #expect(s.scrub("server = 10.0.0.7") == "server = <ipv4>")
        #expect(s.scrub("Address=;40;STA2C1F3D4E;8F2A9C0B1D3E4F5A6B7C8D9E") == "Address=;40;<sta-ticket>")
    }

    @Test func oldFormatTitlesAndAccounts() {
        #expect(s.scrub("TWI window 1a added: appWindow \"Budget 2026.xlsx - Sheets\" rect 0,0 10x10")
                == "TWI window 1a added: appWindow \"<title>\" rect 0,0 10x10")
        #expect(s.scrub("TWI window 2b added: appWindow (12 chars) rect 0,0 10x10") == "TWI window 2b added: appWindow (12 chars) rect 0,0 10x10")
        for account in ["corp\\mmeier", "Corp\\MMeier", "CORP\\mmeier"] {
            #expect(s.scrub("signed in as \(account)") == "signed in as <domain>\\<user>", "\(account)")
        }
        #expect(s.scrub("C:\\Users\\mmeier\\AppData\\Local") == "C:\\Users\\<user>\\AppData\\Local")
    }

    @Test func redirectKeepsTheScheme() {
        #expect(s.scrub("http ↪ 302 → https://portal.example-corp.zz/x") == "http ↪ 302 → https://<host>/x")
        #expect(s.scrub("http ↪ 302 → https://gateway.example-corp.test.com/x") == "http ↪ 302 → https://<gateway>/x")
        #expect(s.scrub("http ↪ 302 → ctxgw01/x") == "http ↪ 302 → <host>/x")
    }

    @Test func privateFilesAre0600InA0700Folder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ica-private-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(PrivateFile.ensureDirectory(dir))   // an existing, too open folder is reset
        func mode(_ url: URL) throws -> Int { try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
        #expect(try mode(dir) == 0o700)
        let file = dir.appendingPathComponent("resource-names.json")
        try Data("[]".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try PrivateFile.write(Data("[\"Paint XYZ\"]".utf8), to: file)   // replaces a 0644 file
        #expect(try mode(file) == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[\"Paint XYZ\"]")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["resource-names.json"])   // no temp left
    }
}

@Suite struct ProblemReportTests {
    static let created = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func markdownHasEverySectionAndASafeFence() {
        let report = ProblemReport(created: Self.created, description: "Windows flicker\nwhen moving.",
                                   environment: ["ICAViewer 0.1 (1), arm64"], settings: ["Audio: on"],
                                   log: ["  1.00 a", "  2.00 ```b```"], logMinutes: 10, appNamesIncluded: false)
        let md = report.markdown
        #expect(md.hasPrefix("# ICAViewer problem report\n"))
        #expect(md.contains("## Description\n\nWindows flicker\nwhen moving.\n"))
        #expect(md.contains("## Environment\n\n- ICAViewer 0.1 (1), arm64\n"))
        #expect(md.contains("## Settings (no secrets)\n\n- Audio: on\n"))
        #expect(md.contains("## Log (last 10 minutes, 2 lines; app names replaced by App 1, App 2, …)"))
        #expect(md.contains("````text\n  1.00 a\n  2.00 ```b```\n````\n"))
        #expect(report.fileName.hasPrefix("ICAViewer-report-") && report.fileName.hasSuffix(".md"))
    }

    @Test func sectionsAreOptional() {
        let md = ProblemReport(created: Self.created, description: "x").markdown
        #expect(!md.contains("## Environment") && !md.contains("## Settings") && !md.contains("## Log"))
    }

    @Test func titleIsTheFirstLineShortened() {
        #expect(ProblemReport(created: Self.created, description: "\n  First line  \nsecond").title == "First line")
        let long = String(repeating: "word ", count: 40)
        let title = ProblemReport(created: Self.created, description: long).title
        #expect(title.count <= 80 && title.hasSuffix("…"))
    }

    @Test func issueURLIsPrefilledAndEncoded() throws {
        let report = ProblemReport(created: Self.created, description: "A & B + C = D?\nline 2",
                                   environment: ["macOS 15.1"], settings: ["Audio: on"])
        let url = report.issueURL()
        let text = url.absoluteString
        #expect(text.hasPrefix("https://github.com/JanHaan/swift-ica-client/issues/new?template=bug_report.yml&title="))
        #expect(text.contains("A%20%26%20B%20%2B%20C%20%3D%20D%3F%0Aline%202"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(values["description"] == "A & B + C = D?\nline 2")
        #expect(values["environment"] == "- macOS 15.1\n- Audio: on")
        #expect(values["title"] == "A & B + C = D?")
        #expect(values["report"]?.contains(report.fileName) == true)
    }

    @Test func issueURLStaysWithinTheLimit() throws {
        let long = (0..<3000).map { "Zeile \($0) mit Umlauten äöü & Sonderzeichen" }.joined(separator: "\n")
        let env = (0..<400).map { "Environment line \($0) with some text" }
        let report = ProblemReport(created: Self.created, description: long, environment: env)
        let url = report.issueURL()
        #expect(url.absoluteString.count <= ProblemReport.urlLimit)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let description = try #require(items.first { $0.name == "description" }?.value)
        #expect(description.hasPrefix("Zeile 0 mit Umlauten äöü"))
        #expect(description.hasSuffix(ProblemReport.truncationNote))
        let environment = try #require(items.first { $0.name == "environment" }?.value)
        #expect(environment.hasPrefix("- Environment line 0") && environment.hasSuffix("- …"))
        // A short report is not shortened.
        let short = ProblemReport(created: Self.created, description: "short").issueURL()
        #expect(!short.absoluteString.contains("shortened"))
    }
}
