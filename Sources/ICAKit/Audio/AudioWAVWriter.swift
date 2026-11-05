import Foundation

/// Writes decoded session audio as 16-bit PCM WAV (docs/98 §11 step 5; icactl audiotest and tests). The first
/// stream's format makes `url`; a later OPEN with another rate or channel count starts `<name>-2.wav`, … .
/// Sounds of one format are joined without the gaps between them. Files are 0600; the RIFF sizes are kept
/// valid after every CLOSE, so a run that dies still leaves a readable file.
///
/// `queue` nil writes inline (tests); otherwise writes go to that queue and the session queue never waits.
public final class AudioWAVWriter: AudioSink {
    public struct File: Sendable {
        public var url: URL
        public var stream: AudioStreamFormat
        public var frames = 0
        /// Largest absolute sample, 0…1.
        public var peak: Float = 0
        public var codes: [AudioFormatCode] = []
        public var seconds: Double { stream.sampleRate > 0 ? Double(frames) / stream.sampleRate : 0 }
    }

    public let url: URL
    private let queue: DispatchQueue?
    private var files: [File] = []
    private var handle: FileHandle?
    private var current: Int?
    private var finished = false

    public init(url: URL, queue: DispatchQueue? = DispatchQueue(label: "ica.audio.wav")) {
        self.url = url
        self.queue = queue
    }

    /// The files written so far (call after `finish` or from the writer's queue for exact values).
    public var written: [File] { sync { files } }

    public func audioOpen(device: UInt8, stream: AudioStreamFormat, code: AudioFormatCode) {
        guard device == AudioWire.playbackDevice else { return }
        run { [self] in
            guard !finished else { return }
            if let index = files.firstIndex(where: { $0.stream == stream }) {
                if index != current { reopen(index) }
            } else {
                closeHandle()
                let n = files.count
                let name = n == 0 ? url : url.deletingLastPathComponent().appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + "-\(n + 1).wav")
                FileManager.default.createFile(atPath: name.path, contents: Self.header(stream: stream, frames: 0),
                                               attributes: [.posixPermissions: 0o600])
                files.append(File(url: name, stream: stream))
                reopen(n)
            }
            if let current, !files[current].codes.contains(code) { files[current].codes.append(code) }
        }
    }

    public func audioWrite(device: UInt8, samples: [Float]) {
        guard device == AudioWire.playbackDevice else { return }
        run { [self] in
            guard !finished, let current, let handle else { return }
            var bytes = [UInt8](repeating: 0, count: samples.count * 2)
            var peak = files[current].peak
            for (i, s) in samples.enumerated() {
                let v = max(-1, min(1, s))
                peak = max(peak, abs(v))
                let q = Int16(clamping: Int((v * 32767).rounded()))
                bytes[2 * i] = UInt8(truncatingIfNeeded: q)
                bytes[2 * i + 1] = UInt8(truncatingIfNeeded: q >> 8)
            }
            handle.write(Data(bytes))
            files[current].frames += samples.count / max(1, files[current].stream.channels)
            files[current].peak = peak
        }
    }

    public func audioClose(device: UInt8) {
        guard device == AudioWire.playbackDevice else { return }
        run { [self] in patchHeader() }
    }

    /// Session end: closes the file without making the session queue wait (`finish` waits).
    public func audioStop() {
        run { [self] in
            guard !finished else { return }
            finished = true
            closeHandle()
        }
    }

    /// Patches the header and closes the file; later writes are ignored.
    public func finish() {
        sync {
            guard !finished else { return }
            finished = true
            closeHandle()
        }
    }

    // MARK: Helpers

    private func run(_ block: @escaping () -> Void) {
        if let queue { queue.async(execute: block) } else { block() }
    }

    private func sync<T>(_ block: () -> T) -> T {
        if let queue { return queue.sync(execute: block) }
        return block()
    }

    private func reopen(_ index: Int) {
        closeHandle()
        guard let h = try? FileHandle(forWritingTo: files[index].url) else { return }
        h.seekToEndOfFile()
        handle = h
        current = index
    }

    private func closeHandle() {
        patchHeader()
        try? handle?.close()
        handle = nil
        current = nil
    }

    private func patchHeader() {
        guard let current, let handle else { return }
        let end = handle.offsetInFile
        handle.seek(toFileOffset: 0)
        handle.write(Self.header(stream: files[current].stream, frames: files[current].frames))
        handle.seek(toFileOffset: end)
    }

    /// The 44-byte RIFF/WAVE header for 16-bit PCM.
    public static func header(stream: AudioStreamFormat, frames: Int) -> Data {
        var w = ByteWriter()
        let channels = UInt16(stream.channels), rate = UInt32(stream.sampleRate)
        let dataBytes = UInt32(frames * Int(channels) * 2)
        w.raw(Array("RIFF".utf8)); w.u32(36 + dataBytes)
        w.raw(Array("WAVE".utf8))
        w.raw(Array("fmt ".utf8)); w.u32(16)
        w.u16(1)                         // PCM
        w.u16(channels)
        w.u32(rate)
        w.u32(rate * UInt32(channels) * 2)  // byte rate
        w.u16(channels * 2)              // block align
        w.u16(16)
        w.raw(Array("data".utf8)); w.u32(dataBytes)
        return w.data
    }
}
