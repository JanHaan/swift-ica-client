import AppHostKit
import Foundation
import IOSurface

/// `--headless` (dockspike ipc-check): the same rendezvous and surface handoff as the app, without
/// AppKit or windows. Answers each probe with the pixel it reads from the shared surface, so the host
/// can check cross-process sharing and measure the round trip.
func runHeadless(_ launch: HelperLaunch) -> Never {
    let link = HostLink(launch: launch)
    var surface: IOSurfaceRef?
    link.onLost = { reason in
        helperLog("host gone (\(reason)); exiting")
        exit(0)
    }
    link.onMessage = { message, port in
        switch message {
        case .surface:
            surface = port != MACH_PORT_NULL ? IOSurfaceLookupFromMachPort(port) : nil
            MachChannel.deallocate(port)
        case .probe(let x, let y, let sentNs):
            let pixel = surface.flatMap { SharedSurface.pixel($0, x: x, y: y) } ?? 0
            link.send(.probeResult(pixel: pixel, seed: surface.map(IOSurfaceGetSeed) ?? 0, sentNs: sentNs))
        case .quit:
            exit(0)
        default:
            MachChannel.deallocate(port)
        }
    }
    if let error = link.connect(queue: .main) {
        helperLog("cannot reach the host: \(error)")
        exit(1)
    }
    dispatchMain()
}
