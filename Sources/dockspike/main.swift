import AppHostKit
import AppKit

// Dock identity spike (docs/99 phase 1): plays the ICAViewer host role offline, with synthetic frames.
setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

let usage = """
usage: dockspike run [--template <ICAViewerHelper.app>] [--apps-dir <dir>] [--fps <n>] [--switch <seconds>] [--duration <seconds>]
         Two helper apps ("Spike Alpha", "Spike Beta") with windows rendered from one shared IOSurface.
         --switch: hand focus to the next window every n s while a helper is frontmost (default off)
         --duration: quit everything after n s (default: until q, Ctrl-C or the last helper exits)
       dockspike generate [--template <app>] [--apps-dir <dir>]   generate and verify the bundles, launch nothing
       dockspike ipc-check [--template <app>]                     headless: rendezvous, surface sharing, latency, exit
       dockspike ax <pid>...                                      ownership report for running processes
       dockspike snapshot <out.png> [--icon <out.png>]           the synthetic surface after 45 frames and a click
   --template defaults to .build/ICAViewerHelper.app (scripts/bundle-helper.sh); --apps-dir to
   ~/Library/Application Support/ICAViewer/Apps
"""

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "run" : args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let template = URL(fileURLWithPath: option("--template") ?? ".build/ICAViewerHelper.app").standardizedFileURL
let appsDirectory = option("--apps-dir").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    ?? HelperBundleGenerator.defaultAppsDirectory

func requireTemplate() {
    guard FileManager.default.fileExists(atPath: template.appendingPathComponent("Contents/Info.plist").path) else {
        print("error: no template at \(template.path); run scripts/bundle-helper.sh first")
        exit(1)
    }
}

switch command {
case "run":
    requireTemplate()
    var options = SpikeHost.Options(template: template, appsDirectory: appsDirectory)
    if let fps = option("--fps").flatMap(Double.init), fps > 0 { options.fps = fps }
    if let s = option("--switch").flatMap(Double.init), s >= 0 { options.switchInterval = s }
    if let d = option("--duration").flatMap(Double.init), d >= 0 { options.duration = d }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)      // the host has no Dock tile: only the helpers do
    guard let host = SpikeHost(options: options) else { print("error: cannot create the surface"); exit(1) }
    host.start()
    app.run()
case "generate":
    requireTemplate()
    let generator = HelperBundleGenerator(template: template, appsDirectory: appsDirectory)
    for h in SpikeHost.defaultHelpers() {
        do {
            let (url, outcome) = try generator.generate(h.label, icon: Scene.icon(letter: h.letter, color: h.color))
            print("\(h.label.name): \(outcome) \(url.path)")
        } catch {
            print("\(h.label.name): error \(error)")
            exit(1)
        }
    }
case "ipc-check":
    requireTemplate()
    IPCCheck.run(template: template)
case "ipc-orphan":                            // internal: host role for ipc-check's lifecycle step
    guard let exe = args.first else { exit(2) }
    IPCCheck.orphanHost(executable: URL(fileURLWithPath: exe))
case "snapshot":
    guard let out = args.first, let scene = Scene(width: 1600, height: 1100) else { print(usage); exit(2) }
    let helpers = SpikeHost.defaultHelpers()
    SpikeHost.populate(scene, helpers)
    for _ in 0..<45 { _ = scene.step() }
    _ = scene.mark(2, at: CGPoint(x: 1000, y: 300))
    scene.setHeader(2, "Spike Beta · last: click (1000, 300)")
    _ = scene.step()
    do {
        try scene.png()?.write(to: URL(fileURLWithPath: out))
        if let iconOut = option("--icon"), let icon = Scene.icon(letter: helpers[0].letter, color: helpers[0].color),
           let data = HelperIcon.icnsData(icon) {
            try data.write(to: URL(fileURLWithPath: iconOut))
        }
    } catch {
        print("error: \(error)")
        exit(1)
    }
case "ax":
    let pids = args.compactMap { pid_t($0) }
    guard !pids.isEmpty else { print(usage); exit(2) }
    AXReport.dump(pids: pids)
default:
    print(usage)
    exit(command == "help" || command == "--help" || command == "-h" ? 0 : 2)
}
