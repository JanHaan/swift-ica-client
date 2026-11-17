import Foundation
import ICAKit

// MARK: - Audio loopback probe (backlog 1.6, D134)

/// `icactl audioprobe [resource]` (lab, "Command Prompt"): playback, and with `ICA_AUDIOPROBE_MIC=1` the microphone,
/// end to end with known signals and no sound on the Mac.
/// - Playback: PowerShell in the session writes a 1 s, 1000 Hz sine WAV to %TEMP% and plays it (Media.SoundPlayer);
///   our decoded audio goes to `.session/audioprobe.wav` and is checked for the 1000 Hz tone (Goertzel against the
///   neighbouring bands).
/// - Microphone: the client announces a capture device fed by a 440 Hz sine (`AudioToneSource`); PowerShell records
///   3 s through winmm (`mciSendString`), saves and plays the recording; the played-back audio must hold 440 Hz.
/// The PowerShell is passed as `-EncodedCommand` (no quoting); it touches only two files in %TEMP%. Logs off at the end.
func runAudioProbe(ica: ICAFile, app: TestApp) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let env = ProcessInfo.processInfo.environment
    let mic = env["ICA_AUDIOPROBE_MIC"] == "1"
    let wavURL = sessionDir.appendingPathComponent("audioprobe.wav")
    try? FileManager.default.removeItem(at: wavURL)
    var audioConfig = AudioEngine.Config()
    audioConfig.codecs = AudioSettings.load(env: env).codecs
    audioConfig.capabilities = AudioWire.Caps.playback
    audioConfig.microphone = mic
    var config = WinstationDriver.Configuration()
    config.expanderPowerOffer = WinstationDriver.Configuration.expanderPowerOffer(environment: env)
    config.logon = WDLogon(ica: ica)
    config.display = WDDisplay(width: 1920, height: 1080)
    let session = try ICASession(ica: ica, configuration: config, clipboard: nil, cdm: nil, printing: nil, audio: audioConfig)
    guard let audio = session.audio else { fail("no audio engine") }
    audio.sink = AudioWAVWriter(url: wavURL)
    if mic { audio.captureSource = AudioToneSource() }
    let seamless = session.seamless
    say("audioprobe: codecs \(audioConfig.codecs.map(\.rawValue).sorted().joined(separator: ",")), microphone \(mic ? "440 Hz tone" : "off")")

    var logon = newLogonDetector()
    var windowsSeen = SeenWindows()
    var appWindows: [UInt32] = []
    var commands: [String] = []
    var recording = false
    var terminateReason: UInt8?
    audio.onEvent = { event in
        switch event {
        case .command(let line):
            commands.append(line)
            if commands.count <= 12 { say("cam: \(line)") }
        case .recording(let on):
            recording = recording || on
            say("cam: capture \(on ? "started" : "stopped")")
        default: say("cam: \(event)")
        }
    }
    seamless.onEvent = { event in
        switch event {
        case .channelReady:
            if let gap = logon.hostInit() { say(freshVerdict(logon, gap, "host init")) }
        case .windowAdded(let w):
            logon.windowAdded(appKey: w.appKey)
            windowsSeen.note(w)
            if w.kind == .appWindow { appWindows.append(w.id) }
            say("TWI window \(w.id) \(w.kind) \"\(w.title)\" app \(w.appKey)")
        case .windowChanged(let w, _): windowsSeen.note(w)
        case .windowRemoved(let w): appWindows.removeAll { $0 == w.id }
        default: break
        }
    }
    session.onThinwireInit = { _ in
        if let gap = logon.thinwireInit() { say(freshVerdict(logon, gap, "Thinwire INIT")) }
    }
    session.onEvent = { event in
        switch event {
        case .log(let text): say(text)
        case .closed(let reason): say("session closed: \(reason)")
        case .wd(.terminate(let reason)):
            terminateReason = reason
            say("← TERMINATE reason \(reason)")
        default: break
        }
    }

    try await session.start()
    let window: () -> UInt32? = {
        appWindows.first { app.matches(executable: windowsSeen.single($0, seamless.model), appKey: windowsSeen.appKey($0)) }
    }
    let found = await waitFor(session, 150) { logon.isFresh && window() != nil }
    let fresh = await onSession(session) { logon.isFresh }
    let target = await onSession(session) { window() }
    var ran = false
    if !fresh {
        say("not a fresh logon by this run: no input is sent")
    } else if !found || target == nil {
        say("no \(app.resource) window: no input is sent")
    } else if let target {
        session.send { _, twi in twi.activate(windowId: target) }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let script = AudioProbeScript.powershell(microphone: mic)
        let command = "powershell -NoProfile -EncodedCommand " + AudioProbeScript.encoded(script)
        say("typing powershell -EncodedCommand (\(script.count) chars of script: a 1 kHz WAV played\(mic ? ", 3 s recorded and played back" : ""))")
        // In chunks: a 3 kB burst of key events lost characters in the console (the microphone script did not run).
        let units = Array(command.utf16)
        for start in stride(from: 0, to: units.count, by: 200) {
            let chunk = units[start..<min(units.count, start + 200)]
            session.sendInput { wd in
                for unit in chunk {
                    wd.keyUnicode(unit, flags: [])
                    wd.keyUnicode(unit, flags: .up)
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        session.sendInput { wd in
            wd.keyScancode(0x1C, up: false)
            wd.keyScancode(0x1C, up: true)
        }
        ran = true
        // Generation (~2 s) + 1 s tone, and with the microphone 3 s recording + 3 s playback.
        let wait: Double = mic ? 30 : 18
        say("listening \(Int(wait)) s")
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 500_000_000) }
        // The console shows PowerShell's errors and the mci results: keep a picture of it.
        say(await audioTestScreenshot(session, target: target, index: 0, file: "audioprobe-console"))
    }

    var ending: String
    if session.isClosed {
        ending = "session ended by the server" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
    } else if !fresh {
        await session.close()
        ending = "disconnected (CGP FINISH), not logged off"
    } else {
        let sent: Bool = await withCheckedContinuation { c in session.logoff { c.resume(returning: $0) } }
        if sent {
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline, !session.isClosed { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if session.isClosed {
            ending = "logged off" + (terminateReason.map { " (TERMINATE reason \($0))" } ?? "")
        } else {
            await session.close()
            ending = "logoff did not end the session in 40 s; disconnected"
        }
    }
    try await Task.sleep(nanoseconds: 500_000_000)
    let rec = await onSession(session) { recording }
    say("\n=== audioprobe summary ===")
    var playOK = false, micOK = !mic
    if let pcm = AudioProbeWAV.read(wavURL) {
        let tone1k = AudioProbeWAV.toneSeconds(pcm, frequency: 1000)
        let tone440 = AudioProbeWAV.toneSeconds(pcm, frequency: 440)
        say(String(format: "decoded audio: %.1f s at %d Hz × %d ch; 1000 Hz present for %.1f s, 440 Hz for %.1f s",
                   Double(pcm.samples.count) / Double(pcm.rate), pcm.rate, pcm.channels, tone1k, tone440))
        playOK = tone1k >= 0.5
        if mic { micOK = rec && tone440 >= 1.0 }
    } else {
        say("no decoded audio (\(wavURL.path) missing or empty)")
    }
    if mic { say("microphone: capture started by the host \(rec)") }
    say("end: \(ending)")
    let pass = fresh && ran && playOK && micOK && ending.hasPrefix("logged off")
    say("RESULT: \(pass ? "PASS" : "FAIL") audioprobe: playback 1 kHz \(playOK)\(mic ? ", microphone 440 Hz loopback \(micOK)" : ""), end: \(ending)")
}

/// The PowerShell the probe types (base64 UTF-16LE for -EncodedCommand).
enum AudioProbeScript {
    static func powershell(microphone: Bool) -> String {
        var s = """
        $sr=44100;$n=$sr;$f="$env:TEMP\\ica-probe-tone.wav";$ms=New-Object IO.MemoryStream;$w=New-Object IO.BinaryWriter($ms);\
        $a=[Text.Encoding]::ASCII;$w.Write($a.GetBytes('RIFF'));$w.Write([int](36+$n*2));$w.Write($a.GetBytes('WAVEfmt '));\
        $w.Write([int]16);$w.Write([int16]1);$w.Write([int16]1);$w.Write([int]$sr);$w.Write([int]($sr*2));$w.Write([int16]2);\
        $w.Write([int16]16);$w.Write($a.GetBytes('data'));$w.Write([int]($n*2));\
        for($i=0;$i -lt $n;$i++){$w.Write([int16](12000*[Math]::Sin(2*[Math]::PI*1000*$i/$sr)))};$w.Flush();\
        [IO.File]::WriteAllBytes($f,$ms.ToArray());(New-Object Media.SoundPlayer $f).PlaySync();Remove-Item $f;
        """
        if microphone {
            s += """
            Add-Type -Name M -Namespace W -MemberDefinition '[DllImport("winmm.dll")] public static extern int mciSendString(string c, System.Text.StringBuilder r, int l, IntPtr h);';\
            $r="$env:TEMP\\ica-probe-rec.wav";'mci open '+[W.M]::mciSendString('open new type waveaudio alias rec',$null,0,0);\
            'mci set '+[W.M]::mciSendString('set rec bitspersample 16 samplespersec 48000 channels 2 bytespersec 192000 alignment 4',$null,0,0);\
            'mci record '+[W.M]::mciSendString('record rec',$null,0,0);Start-Sleep 3;'mci save '+[W.M]::mciSendString('save rec '+$r,$null,0,0);\
            [W.M]::mciSendString('close rec',$null,0,0)|Out-Null;(New-Object Media.SoundPlayer $r).PlaySync();Remove-Item $r;
            """
        }
        return s
    }

    static func encoded(_ script: String) -> String {
        Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
    }
}

/// Reads the probe's WAV (16-bit PCM) and finds tones.
enum AudioProbeWAV {
    struct PCM { var rate: Int; var channels: Int; var samples: [Float] }   // mono mix

    static func read(_ url: URL) -> PCM? {
        guard let d = try? Data(contentsOf: url), d.count > 44, d.prefix(4) == Data("RIFF".utf8) else { return nil }
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var i = 12, rate = 0, channels = 0, bits = 0
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<i + 4], as: UTF8.self), size = u32(i + 4)
            if id == "fmt " { channels = u16(i + 10); rate = u32(i + 12); bits = u16(i + 22) }
            if id == "data", bits == 16, channels > 0 {
                let end = min(b.count, i + 8 + size)
                var out: [Float] = []
                var j = i + 8
                while j + 2 * channels <= end {
                    var sum: Float = 0
                    for c in 0..<channels { sum += Float(Int16(bitPattern: UInt16(u16(j + 2 * c)))) }
                    out.append(sum / Float(channels) / 32768)
                    j += 2 * channels
                }
                return PCM(rate: rate, channels: channels, samples: out)
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }

    /// Seconds (in 50 ms blocks) where `frequency` holds most of the block's energy (Goertzel vs. ±30 % bands) and the
    /// block is not silent.
    static func toneSeconds(_ pcm: PCM, frequency: Double) -> Double {
        let block = max(1, pcm.rate / 20)
        var hits = 0
        var start = 0
        while start + block <= pcm.samples.count {
            let s = Array(pcm.samples[start..<start + block])
            let rms = (s.reduce(0) { $0 + Double($1 * $1) } / Double(block)).squareRoot()
            if rms > 0.01 {
                let p = goertzel(s, frequency, pcm.rate)
                let lo = goertzel(s, frequency * 0.7, pcm.rate), hi = goertzel(s, frequency * 1.3, pcm.rate)
                if p > 10 * max(lo, hi) { hits += 1 }
            }
            start += block
        }
        return Double(hits) * 0.05
    }

    static func goertzel(_ s: [Float], _ f: Double, _ rate: Int) -> Double {
        let k = 2 * cos(2 * Double.pi * f / Double(rate))
        var q1 = 0.0, q2 = 0.0
        for x in s {
            let q0 = k * q1 - q2 + Double(x)
            q2 = q1
            q1 = q0
        }
        return q1 * q1 + q2 * q2 - k * q1 * q2
    }
}
