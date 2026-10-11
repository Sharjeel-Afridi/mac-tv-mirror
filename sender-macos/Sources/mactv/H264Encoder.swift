import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

struct EncodedFrame {
    let annexB: Data
    let isKeyframe: Bool
    let ptsMicros: UInt64
}

enum EncoderError: Error, CustomStringConvertible {
    case sessionCreate(OSStatus)

    var description: String {
        switch self {
        case .sessionCreate(let s): return "VTCompressionSessionCreate failed (\(s))"
        }
    }
}

/// Hardware H.264 encoder tuned for screen mirroring: realtime, no frame reordering (no B-frames),
/// short keyframe interval, low-latency rate control when the platform offers it.
/// Output is Annex-B with SPS/PPS prepended to every keyframe.
final class H264Encoder {
    struct Config {
        var width: Int
        var height: Int
        var fps: Int
        var bitrate: Int
    }

    let config: Config
    private(set) var usingLowLatencyRateControl = false

    /// Annex-B SPS+PPS, delivered whenever they change and always before the first keyframe.
    var onParameterSets: ((Data) -> Void)?
    var onFrame: ((EncodedFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    private var lastParameterSets: Data?

    init(config: Config) throws {
        self.config = config
        try createSession()
    }

    deinit {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        lock.lock()
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        var props: [CFString: Any] = [:]
        if key { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = true }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props.isEmpty ? nil : props as CFDictionary,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr else {
                Log.warn("encoder: frame failed (\(status))")
                return
            }
            guard let sampleBuffer else { return }
            self.handle(sampleBuffer)
        }
        if status != noErr {
            Log.warn("encoder: encode call failed (\(status))")
        }
    }

    func flush() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    // MARK: - Session

    private func createSession() throws {
        var created: VTCompressionSession?
        var status: OSStatus = noErr

        // Prefer the low-latency rate controller (Apple Silicon, macOS 11.3+); fall back if refused.
        for lowLatency in [true, false] {
            var spec: [CFString: Any] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            ]
            if lowLatency {
                spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
            }
            status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(config.width),
                height: Int32(config.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
            if status == noErr, created != nil {
                usingLowLatencyRateControl = lowLatency
                break
            }
        }
        guard status == noErr, let session = created else {
            throw EncoderError.sessionCreate(status)
        }
        self.session = session

        func set(_ key: CFString, _ value: Any) {
            let result = VTSessionSetProperty(session, key: key, value: value as AnyObject)
            if result != noErr {
                Log.debug("encoder: property \(key) not accepted (\(result))")
            }
        }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, config.fps * 2)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, config.fps)
        set(kVTCompressionPropertyKey_AverageBitRate, config.bitrate)
        // Hard cap: 1.5× the average over any one-second window (bytes, seconds).
        set(kVTCompressionPropertyKey_DataRateLimits, [config.bitrate / 8 * 3 / 2, 1])
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    // MARK: - Output

    /// Runs on VideoToolbox's output thread, serialized per session, in presentation order
    /// (frame reordering is disabled).
    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let isKey = Self.isKeyframe(sampleBuffer)

        var nalLengthSize: Int32 = 4
        var parameterSetCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: &nalLengthSize)

        var parameterSets = Data()
        if isKey {
            parameterSets = Self.annexBParameterSets(format, count: parameterSetCount)
            if parameterSets != lastParameterSets {
                lastParameterSets = parameterSets
                onParameterSets?(parameterSets)
            }
        }

        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        let copyStatus = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
        }
        guard copyStatus == noErr else {
            Log.warn("encoder: could not copy sample data (\(copyStatus))")
            return
        }

        // AVCC (length-prefixed NALs) → Annex-B (start-code-prefixed NALs).
        var annexB = Data(capacity: total + parameterSets.count + 64)
        annexB.append(parameterSets)
        let n = Int(nalLengthSize)
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + n <= total {
                var length = 0
                for i in 0..<n { length = (length << 8) | Int(raw[offset + i]) }
                offset += n
                guard length > 0, offset + length <= total else { break }
                annexB.append(contentsOf: [0, 0, 0, 1])
                annexB.append(contentsOf: raw[offset..<offset + length])
                offset += length
            }
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros: UInt64 = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000) : 0
        onFrame?(EncodedFrame(annexB: annexB, isKeyframe: isKey, ptsMicros: micros))
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            return !notSync
        }
        return true
    }

    private static func annexBParameterSets(_ format: CMFormatDescription, count: Int) -> Data {
        var out = Data()
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let p = pointer else { continue }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(p, count: size)
        }
        return out
    }
}
