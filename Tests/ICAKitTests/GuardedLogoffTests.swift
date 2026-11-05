import Testing
@testable import ICAKit

@Test func guardedLogoffDecision() {
    let list = GuardedLogoff.parseList(" Win32Calc.exe ,C:\\Tools\\other.EXE,")
    #expect(list == ["win32calc.exe", "other.exe"])
    #expect(GuardedLogoff.basename("C:\\Windows\\System32\\win32calc.exe") == "win32calc.exe")
    #expect(GuardedLogoff.basename("/x/y/Z.exe") == "z.exe")

    let calc = "C:\\Windows\\System32\\win32calc.exe"
    let logon = "C:\\Windows\\System32\\LogonUI.exe"
    let cmd = "C:\\Windows\\System32\\cmd.exe"
    #expect(GuardedLogoff.decide(allowList: list, windowExecutables: [calc, logon, calc])
            == .allowed(seen: ["logonui.exe", "win32calc.exe"]))
    // cmd.exe only when listed.
    #expect(GuardedLogoff.decide(allowList: list, windowExecutables: [calc, cmd]) == .refused(seen: ["cmd.exe", "win32calc.exe"]))
    #expect(GuardedLogoff.decide(allowList: list.union(["cmd.exe"]), windowExecutables: [calc, logon, cmd])
            == .allowed(seen: ["cmd.exe", "logonui.exe", "win32calc.exe"]))
    #expect(GuardedLogoff.decide(allowList: ["cmd.exe", "logonui.exe"], windowExecutables: [logon]) == .refused(seen: ["logonui.exe"]))
    // Any other window refuses.
    #expect(GuardedLogoff.decide(allowList: list, windowExecutables: [calc, "C:\\Program Files\\Outlook\\OUTLOOK.EXE"])
            == .refused(seen: ["outlook.exe", "win32calc.exe"]))
    // A window whose executable is unknown refuses.
    #expect(GuardedLogoff.decide(allowList: list, windowExecutables: [calc, nil, ""]) == .refused(seen: ["(unknown)", "win32calc.exe"]))
    // No window at all, or only logon/console windows, refuses.
    #expect(GuardedLogoff.decide(allowList: list, windowExecutables: []) == .refused(seen: []))
    #expect(GuardedLogoff.decide(allowList: list, windowExecutables: [logon, cmd]) == .refused(seen: ["cmd.exe", "logonui.exe"]))
    // An empty list never allows.
    #expect(GuardedLogoff.decide(allowList: [], windowExecutables: [calc]) == .refused(seen: ["win32calc.exe"]))
}
