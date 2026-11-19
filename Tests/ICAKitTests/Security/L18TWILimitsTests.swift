import Testing
import Foundation
@testable import ICAKit

// Security review (docs/security/asvs-review.md §8 L-18 and §10 F-10, mac-S): a session host must not make the TWI
// model or the chunk reassembly grow without bound (docs/50 §7.2). Offline.

private func create(_ id: UInt32, pid: UInt32? = nil) -> TWIHostMessage {
    .create(TWICreate(source: .v2, id: id, flags: 0, style: 0x10C0_0000, exStyle: 0, windowRect: .zero, clientRect: .zero,
                      ownerId: 0, processId: pid, appId: "App.\(id)", title: "w"))
}

@Suite struct L18TWILimitsTests {
    @Test func windowsBeyondTheCapAreRefusedWithoutResendRequests() {
        let model = WindowModel()
        model.maxWindows = 64   // the per-message cost grows with the count; the default (4,096) works the same way
        var limits: [String] = [], resends = 0
        model.onLimit = { limits.append($0) }
        model.onResendNeeded = { _ in resends += 1 }
        let start = Date()
        for id in 1...UInt32(model.maxWindows + 500) { model.apply(create(id)) }
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(model.windows.count == model.maxWindows)
        #expect(model.refusedWindowCount == 500)
        #expect(limits.count == 1)
        // A change for a refused window asks for nothing while the cap holds.
        let partial = TWIChange(id: UInt32(model.maxWindows + 1), mask: TWIChangeMask(rawValue: 0x01), flags: 0)
        model.apply(.change(partial))
        #expect(resends == 0)
        // Once a window closes, an unknown window may be asked for again.
        model.apply(.destroy(windowId: 1))
        model.apply(.change(partial))
        #expect(resends == 1)
    }

    @Test func iconsAndProcessesAreBounded() {
        let model = WindowModel()
        // Icons for windows that never come: at most maxPendingIconWindows windows of maxIconsPerWindow types.
        for id in UInt32(10_000)..<10_500 {
            for type in UInt32(0)..<20 { model.setIcon(windowId: id, type: type, blob: Data([1, 2, 3])) }
        }
        let pending = model.pendingIconsForTests
        #expect(pending.count == WindowModel.maxPendingIconWindows)
        #expect(pending.values.allSatisfy { $0 <= WindowModel.maxIconsPerWindow })
        // A real window keeps at most maxIconsPerWindow types; the same type replaces.
        model.apply(create(1))
        for type in UInt32(0)..<50 { model.setIcon(windowId: 1, type: type, blob: Data([4])) }
        #expect(model.windows[1]?.icons.count == WindowModel.maxIconsPerWindow)
        // Processes: capped; PROCESS_ENDED floods do not grow the set past the cap.
        for pid in UInt32(1)...UInt32(WindowModel.maxProcesses + 100) {
            model.apply(.processCreated(TWIProcessInfo(processId: pid, parentId: 0, flags: 0, stringA: "", executablePath: "C:\\a.exe", appName: "")))
        }
        #expect(model.processes.count == WindowModel.maxProcesses && model.refusedProcessCount == 100)
        for pid in UInt32(100_000)..<UInt32(120_000) { model.apply(.processEnded(processId: pid, flags: 0)) }
        #expect(model.endedProcesses.count <= WindowModel.maxProcesses)
    }

    /// F-10: chunked icons and bitmaps that never end, or grow past their cap, are dropped.
    @Test func chunkReassemblyIsBounded() {
        var a = TWIChunkAssembler()
        let chunk = Data(repeating: 0xAB, count: 60_000)
        // One icon that never ends.
        for _ in 0..<100 { _ = a.add(TWIIconChunk(windowId: 1, processId: 1, iconType: 0, flags: 0x80, totalSize: nil, data: chunk)) }
        #expect(a.pendingBytes <= TWIChunkAssembler.maxIconBytes)
        #expect(a.dropped > 0)
        // Many icons started at once.
        for w in UInt32(2)..<200 { _ = a.add(TWIIconChunk(windowId: w, processId: 1, iconType: 0, flags: 0xC0, totalSize: nil, data: chunk)) }
        #expect(a.pendingCount <= TWIChunkAssembler.maxPending)
        // A complete icon over the cap is not delivered.
        var b = TWIChunkAssembler()
        #expect(b.add(TWIIconChunk(windowId: 1, processId: 1, iconType: 0, flags: 0x40, totalSize: nil,
                                   data: Data(count: TWIChunkAssembler.maxIconBytes + 1))) == nil)
        // An ordinary icon in three chunks still arrives whole.
        var c = TWIChunkAssembler()
        _ = c.add(TWIIconChunk(windowId: 7, processId: 1, iconType: 1, flags: 0xC0, totalSize: nil, data: Data([1])))
        _ = c.add(TWIIconChunk(windowId: 7, processId: 1, iconType: 1, flags: 0x80, totalSize: nil, data: Data([2])))
        let done = c.add(TWIIconChunk(windowId: 7, processId: 1, iconType: 1, flags: 0x00, totalSize: nil, data: Data([3])))
        #expect(done?.blob == Data([1, 2, 3]) && done?.windowId == 7)
    }
}
