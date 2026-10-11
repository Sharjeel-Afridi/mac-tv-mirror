import Foundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

enum CaptureError: Error, CustomStringConvertible {
    case noSuchDisplay(Int, available: Int)

    var description: String {
        switch self {
        case let .noSuchDisplay(index, available):
            return "display \(index) does not exist (\(available) available; see `mactv list`)"
        }
    }
}

struct DisplayInfo {
    let index: Int
    let display: SCDisplay
    let pixelWidth: Int
    let pixelHeight: Int

    var isMain: Bool { CGDisplayIsMain(display.displayID) != 0 }
}

/// Captures one display with ScreenCaptureKit and hands out NV12 pixel buffers.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Options {
        var displayIndex = 0
        var maxWidth = 1920
        var maxHeight = 1080
        var fps = 30
        var showsCursor = true
    }

    private(set) var outputWidth = 0
    private(set) var outputHeight = 0
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "mactv.capture", qos: .userInteractive)

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStopped: ((Error?) -> Void)?

    static func displays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.enumerated().map { index, display in
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            return DisplayInfo(
                index: index,
                display: display,
                pixelWidth: mode?.pixelWidth ?? display.width,
                pixelHeight: mode?.pixelHeight ?? display.height)
        }
    }

    /// Scale (w, h) to fit inside (maxW, maxH), keeping aspect ratio, rounded to even numbers.
    static func fit(_ w: Int, _ h: Int, maxW: Int, maxH: Int) -> (Int, Int) {
        let scale = min(1.0, Double(maxW) / Double(w), Double(maxH) / Double(h))
        let fw = max(2, Int(Double(w) * scale) & ~1)
        let fh = max(2, Int(Double(h) * scale) & ~1)
        return (fw, fh)
    }

    func start(options: Options) async throws {
        let displays = try await Self.displays()
        guard options.displayIndex >= 0, options.displayIndex < displays.count else {
            throw CaptureError.noSuchDisplay(options.displayIndex, available: displays.count)
        }
        let info = displays[options.displayIndex]
        let (w, h) = Self.fit(info.pixelWidth, info.pixelHeight, maxW: options.maxWidth, maxH: options.maxHeight)
        outputWidth = w
        outputHeight = h

        let filter = SCContentFilter(display: info.display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = options.showsCursor
        config.queueDepth = 5
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("capturing display \(options.displayIndex) (\(info.pixelWidth)×\(info.pixelHeight)) as \(w)×\(h) @ \(options.fps) fps")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // ScreenCaptureKit emits .idle/.blank frames when nothing changed; only encode complete ones.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let statusRaw = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.warn("capture stopped: \(error.localizedDescription)")
        onStopped?(error)
    }
}

/// Human-readable hint for the one error everybody hits first.
func describeCaptureError(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && (ns.code == -3801 || ns.code == -3802) {
        return """
        Screen Recording permission is missing for the app that launched mactv (your terminal).
        Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then re-run.
        (\(ns.localizedDescription))
        """
    }
    return ns.localizedDescription
}
