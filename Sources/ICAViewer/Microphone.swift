import AppKit
import AVFoundation
import ICAKit

/// The Mac microphone as the session's capture device (docs/98 §10.3). Lives in the app only: icactl has no
/// microphone path (it uses `AudioToneSource`). Nothing is ever written to disk.
///
/// - Permission is asked for only when the host OPENs the capture device (`requestPermission`), never at launch.
/// - The input node exists only between START_RECORD and STOP_RECORD/CLOSE/suspend/session end; macOS shows its
///   own microphone indicator meanwhile.
/// - The tap's buffers are converted to the OPEN's rate and channel count (AVAudioConverter; mono input feeds
///   both channels of a stereo stream).
final class Microphone: AudioCaptureSource {
    enum Failure: Error, CustomStringConvertible {
        case noInput, noConverter
        var description: String {
            switch self {
            case .noInput: return "no audio input device"
            case .noConverter: return "cannot convert the input to the session format"
            }
        }
    }

    private let lock = NSLock()
    private var engine: AVAudioEngine?

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default: completion(false)
        }
    }

    func start(format: AudioStreamFormat, deliver: @escaping ([Float]) -> Void) throws {
        stop()
        let e = AVAudioEngine()
        let input = e.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Failure.noInput }
        let channels = format.channels
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: hardware, to: target) else { throw Failure.noConverter }
        if hardware.channelCount == 1, channels == 2 { converter.channelMap = [0, 0] }
        if hardware.channelCount > AVAudioChannelCount(channels) { converter.downmix = true }
        let ratio = format.sampleRate / hardware.sampleRate
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hardware.sampleRate * 0.02), format: hardware) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            _ = converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let p = out.floatChannelData?[0] else { return }
            deliver(Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength) * channels)))
        }
        e.prepare()
        do { try e.start() } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        lock.lock()
        engine = e
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let e = engine
        engine = nil
        lock.unlock()
        guard let e else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
    }
}

// The permission note and the menu-bar indicator are shared with the camera: DevicesInUse.swift.
