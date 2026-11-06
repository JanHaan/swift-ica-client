import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// H.264 byte-stream helpers (ITU-T H.264 Annex B; docs/98b §7.1, §10.3). VideoToolbox emits AVCC (length-prefixed
/// NAL units, SPS/PPS in the format description); the host gets Annex B: every NAL behind `00 00 00 01`, and on
/// every sync sample the SPS and PPS in front of the IDR.
public enum AnnexB {
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    /// NAL unit types used here.
    public enum NALType {
        public static let idr: UInt8 = 5
        public static let sei: UInt8 = 6
        public static let sps: UInt8 = 7
        public static let pps: UInt8 = 8
    }

    /// The NAL units of an AVCC sample (big-endian length prefixes of `lengthSize` bytes: 1, 2 or 4). Nil if a
    /// length runs past the end or is zero.
    public static func avccUnits(_ avcc: Data, lengthSize: Int) -> [Data]? {
        guard [1, 2, 4].contains(lengthSize) else { return nil }
        var units: [Data] = []
        var at = avcc.startIndex
        while at < avcc.endIndex {
            guard avcc.endIndex - at >= lengthSize else { return nil }
            var n = 0
            for i in 0..<lengthSize { n = n << 8 | Int(avcc[at + i]) }
            at += lengthSize
            guard n > 0, avcc.endIndex - at >= n else { return nil }
            units.append(avcc.subdata(in: at..<at + n))
            at += n
        }
        return units
    }

    /// AVCC → Annex B. On a sync sample `parameterSets` (SPS, PPS, …) go first unless the sample already carries an
    /// SPS. Nil for a malformed sample.
    public static func fromAVCC(_ avcc: Data, lengthSize: Int, sync: Bool, parameterSets: [Data]) -> Data? {
        guard let units = avccUnits(avcc, lengthSize: lengthSize), !units.isEmpty else { return nil }
        var out = Data()
        out.reserveCapacity(avcc.count + parameterSets.reduce(0) { $0 + $1.count + 4 } + 4 * units.count)
        if sync, !units.contains(where: { nalType($0) == NALType.sps }) {
            for set in parameterSets {
                out.append(contentsOf: startCode)
                out.append(set)
            }
        }
        for unit in units {
            out.append(contentsOf: startCode)
            out.append(unit)
        }
        return out
    }

    public static func nalType(_ unit: Data) -> UInt8? { unit.first.map { $0 & 0x1F } }

    /// The NAL units of an Annex B stream (3- and 4-byte start codes); for checks and logs.
    public static func units(_ stream: Data) -> [Data] {
        let b = [UInt8](stream)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                starts.append((i > 0 && b[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.enumerated().map { index, s in
            let end = index + 1 < starts.count ? starts[index + 1].code : b.count
            return Data(b[s.payload..<max(s.payload, end)])
        }
    }
}

/// One encoded frame, ready for TRANSMIT: Annex B, SPS/PPS in front on a key frame.
public struct WebcamEncodedSample: Sendable {
    public var data: Data
    public var isKeyFrame: Bool
    /// The frame's presentation time in seconds (for the key-frame interval).
    public var time: Double

    public init(data: Data, isKeyFrame: Bool, time: Double) {
        self.data = data
        self.isKeyFrame = isKeyFrame
        self.time = time
    }
}

/// Encodes 352×288 frames to H.264 Annex B samples. `completion` runs once per `encode`, on any thread; nil = the
/// frame was dropped or failed.
public protocol WebcamVideoEncoder: AnyObject {
    func encode(_ frame: CVPixelBuffer, time: CMTime, forceKeyFrame: Bool, completion: @escaping (WebcamEncodedSample?) -> Void)
    /// Emits what is still pending (tests, end of stream).
    func flush()
    /// Releases the encoder; no completion runs after it returns.
    func invalidate()
}

/// VideoToolbox H.264 (docs/98b §10.3): real time, Constrained Baseline (Baseline before macOS 12), no frame
/// reordering, CAVLC, 160 kbit/s average with a 1.5× one-second cap, 15 fps expected, a key frame at least every
/// 30 frames / 2 s, low-latency rate control where the encoder offers it. No software fallback library (D37).
public final class WebcamH264Encoder: WebcamVideoEncoder {
    public enum Failure: Error, CustomStringConvertible {
        case create(OSStatus)
        public var description: String {
            switch self {
            case .create(let s): return "VTCompressionSessionCreate failed (\(s))"
            }
        }
    }

    public let format: WebcamFormat
    /// Properties the encoder refused (logged by the engine; the session still works without them).
    public private(set) var refusedProperties: [String] = []
    public private(set) var lowLatency = false
    private var session: VTCompressionSession?
    private let lock = NSLock()

    public init(format: WebcamFormat = .standard) throws {
        self.format = format
        var created: VTCompressionSession?
        var status = OSStatus(-1)
        // Low-latency rate control first (macOS 11.3+); without it if this Mac's encoder refuses.
        for spec in [[kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary, nil] {
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(format.width), height: Int32(format.height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if status == noErr, created != nil {
                lowLatency = spec != nil
                break
            }
        }
        guard status == noErr, let s = created else { throw Failure.create(status) }
        session = s
        func set(_ key: CFString, _ value: CFTypeRef, _ name: String) {
            if VTSessionSetProperty(s, key: key, value: value) != noErr { refusedProperties.append(name) }
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        if VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel) != noErr {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel, "ProfileLevel")
        }
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")
        set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CAVLC, "H264EntropyMode")
        set(kVTCompressionPropertyKey_AverageBitRate, format.bitRate as CFNumber, "AverageBitRate")
        let bytesPerSecond = format.bitRate * 3 / 2 / 8
        set(kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond, 1] as CFArray, "DataRateLimits")
        set(kVTCompressionPropertyKey_ExpectedFrameRate, format.frameRate as CFNumber, "ExpectedFrameRate")
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (format.frameRate * 2) as CFNumber, "MaxKeyFrameInterval")
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2.0 as CFNumber, "MaxKeyFrameIntervalDuration")
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    public func encode(_ frame: CVPixelBuffer, time: CMTime, forceKeyFrame: Bool, completion: @escaping (WebcamEncodedSample?) -> Void) {
        lock.lock()
        let s = session
        lock.unlock()
        guard let s else { return completion(nil) }
        let options = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let seconds = time.seconds
        let status = VTCompressionSessionEncodeFrame(s, imageBuffer: frame, presentationTimeStamp: time, duration: .invalid,
                                                     frameProperties: options, infoFlagsOut: nil) { status, flags, sample in
            guard status == noErr, !flags.contains(.frameDropped), let sample else { return completion(nil) }
            completion(Self.annexB(sample, time: seconds))
        }
        if status != noErr { completion(nil) }
    }

    public func flush() {
        lock.lock()
        let s = session
        lock.unlock()
        if let s { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid) }
    }

    public func invalidate() {
        lock.lock()
        let s = session
        session = nil
        lock.unlock()
        if let s { VTCompressionSessionInvalidate(s) }
    }

    /// An encoded CMSampleBuffer as Annex B (§10.3): sync unless `kCMSampleAttachmentKey_NotSync` is true; on sync the
    /// parameter sets from the format description go first; length prefixes become start codes.
    public static func annexB(_ sample: CMSampleBuffer, time: Double) -> WebcamEncodedSample? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let description = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var sync = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            sync = !notSync
        }
        var count = 0
        var lengthSize: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                           nalUnitHeaderLengthOut: &lengthSize)
        var sets: [Data] = []
        if sync {
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr,
              let data = AnnexB.fromAVCC(avcc, lengthSize: Int(lengthSize), sync: sync, parameterSets: sets) else { return nil }
        return WebcamEncodedSample(data: data, isKeyFrame: sync, time: time)
    }
}

/// Scales and centre-crops camera frames to 352×288 NV12 (docs/98b §10.1: aspect fill, crop to 11:9, so faces are not
/// stretched). VideoToolbox pixel transfer with the source's clean aperture set to the crop. Use from one queue.
public final class WebcamFrameScaler {
    public let format: WebcamFormat
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    public init(format: WebcamFormat = .standard) {
        self.format = format
        var t: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &t) == noErr, let t {
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_CropSourceToCleanAperture)
            transfer = t
        }
        pool = WebcamPixelBuffers.pool(format)
    }

    deinit { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }

    /// The centred crop of a `width × height` source with the target's aspect ratio (even sizes).
    public static func crop(width: Int, height: Int, to format: WebcamFormat) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        if width * format.height > height * format.width {
            return (min(width, (height * format.width / format.height) & ~1), height & ~1)
        }
        return (width & ~1, min(height, (width * format.height / format.width) & ~1))
    }

    /// A new 352×288 NV12 buffer with the cropped and scaled picture; the source passes through if it already has
    /// the size. Nil on failure (the frame is skipped).
    public func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source)
        if w == format.width, h == format.height, CVPixelBufferGetPixelFormatType(source) == WebcamPixelBuffers.pixelFormat { return source }
        guard let transfer, let pool else { return nil }
        let c = Self.crop(width: w, height: h, to: format)
        let aperture: [CFString: Any] = [
            kCVImageBufferCleanApertureWidthKey: c.width, kCVImageBufferCleanApertureHeightKey: c.height,
            kCVImageBufferCleanApertureHorizontalOffsetKey: 0, kCVImageBufferCleanApertureVerticalOffsetKey: 0,
        ]
        CVBufferSetAttachment(source, kCVImageBufferCleanApertureKey, aperture as CFDictionary, .shouldNotPropagate)
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: out) == noErr else { return nil }
        return out
    }
}

/// Pixel buffer helpers for the webcam path (NV12, IOSurface-backed so VideoToolbox can use them directly).
public enum WebcamPixelBuffers {
    public static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    public static func pool(_ format: WebcamFormat) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height, kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }
}
