import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo

/// Generates a moving test pattern so the encoder, protocol and receiver can be exercised without
/// Screen Recording permission. The bottom strip encodes the frame number in binary, which makes
/// glass-to-glass latency measurable from a photo of the Mac and the TV side by side.
final class SyntheticSource {
    let width: Int
    let height: Int
    let fps: Int

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private var pool: CVPixelBufferPool?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "mactv.synthetic", qos: .userInteractive)
    private var frameIndex = 0
    private let startTime = CMClockGetTime(CMClockGetHostTimeClock())

    init(width: Int, height: Int, fps: Int) {
        self.width = width & ~1
        self.height = height & ~1
        self.fps = fps
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: self.width,
            kCVPixelBufferHeightKey: self.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let pool else { return }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { return }
        draw(into: buffer)
        let pts = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), startTime)
        frameIndex += 1
        onFrame?(buffer, pts)
    }

    private func draw(into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // CoreGraphics puts the origin bottom-left; flip so y grows downward like the screen.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let bars: [CGColor] = [
            CGColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1),
            CGColor(red: 0.75, green: 0.75, blue: 0.00, alpha: 1),
            CGColor(red: 0.00, green: 0.75, blue: 0.75, alpha: 1),
            CGColor(red: 0.00, green: 0.75, blue: 0.00, alpha: 1),
            CGColor(red: 0.75, green: 0.00, blue: 0.75, alpha: 1),
            CGColor(red: 0.75, green: 0.00, blue: 0.00, alpha: 1),
            CGColor(red: 0.00, green: 0.00, blue: 0.75, alpha: 1),
            CGColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        ]
        let w = CGFloat(width)
        let h = CGFloat(height)

        let barWidth = w / CGFloat(bars.count)
        for (i, color) in bars.enumerated() {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: CGFloat(i) * barWidth, y: 0, width: barWidth + 1, height: h))
        }

        // Bouncing square: motion for the encoder to work on, and a visual latency cue.
        let t = Double(frameIndex) / Double(fps)
        let size = h / 6
        let x = CGFloat((sin(t * 1.5) + 1) / 2) * (w - size)
        let y = CGFloat((cos(t * 1.1) + 1) / 2) * (h - size)
        ctx.setFillColor(white)
        ctx.fill(CGRect(x: x, y: y, width: size, height: size))
        ctx.setFillColor(black)
        ctx.fill(CGRect(x: x + size * 0.25, y: y + size * 0.25, width: size * 0.5, height: size * 0.5))

        // Sweep bar: one full pass per second.
        let sweep = CGFloat(frameIndex % fps) / CGFloat(fps)
        ctx.setFillColor(white)
        ctx.fill(CGRect(x: sweep * w, y: h * 0.45, width: max(4, w / 100), height: h * 0.1))

        // Frame counter, 16-bit binary strip along the bottom (LSB on the left).
        let bits = 16
        let cell = w / CGFloat(bits)
        for b in 0..<bits {
            let on = (frameIndex >> b) & 1 == 1
            ctx.setFillColor(on ? white : black)
            ctx.fill(CGRect(x: CGFloat(b) * cell + 1, y: h - cell / 2, width: cell - 2, height: cell / 2))
        }
    }
}
