import Foundation
import CoreMedia
import CoreVideo

/// Where encoded frames go: the network, or a file.
protocol FrameSink: AnyObject {
    func sendHello(_ hello: HelloInfo)
    func sendConfig(_ annexB: Data)
    func sendFrame(_ frame: EncodedFrame)
    func stop()
}

final class NetworkSink: FrameSink {
    let sender: StreamSender

    init(sender: StreamSender) {
        self.sender = sender
    }

    func sendHello(_ hello: HelloInfo) {
        let json = (try? JSONEncoder().encode(hello)) ?? Data()
        sender.sendMessage(type: .hello, payload: json)
    }

    func sendConfig(_ annexB: Data) {
        sender.sendMessage(type: .videoConfig, payload: annexB)
    }

    func sendFrame(_ frame: EncodedFrame) {
        sender.sendVideo(frame)
    }

    func stop() {
        sender.stop()
    }
}

final class FileSink: FrameSink {
    private let handle: FileHandle
    private let lock = NSLock()
    private(set) var frames = 0
    private(set) var keyframes = 0
    private(set) var bytes = 0

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    }

    func sendHello(_ hello: HelloInfo) {}

    // Parameter sets are already in-band ahead of every keyframe; writing them again would
    // only duplicate them in the file.
    func sendConfig(_ annexB: Data) {}

    func sendFrame(_ frame: EncodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        handle.write(frame.annexB)
        frames += 1
        bytes += frame.annexB.count
        if frame.isKeyframe { keyframes += 1 }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }
}

/// Wires a frame source (screen or synthetic) through the encoder into a sink.
final class Pipeline {
    let encoder: H264Encoder
    let sink: FrameSink
    private var encodedFrames = 0
    private var encodedBytes = 0
    private let statsLock = NSLock()
    private var statsTimer: DispatchSourceTimer?
    private var lastStats = (frames: 0, bytes: 0, time: Date())

    init(encoder: H264Encoder, sink: FrameSink) {
        self.encoder = encoder
        self.sink = sink
        encoder.onParameterSets = { [weak self] ps in
            Log.debug("parameter sets: \(ps.count) bytes")
            self?.sink.sendConfig(ps)
        }
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.statsLock.lock()
            self.encodedFrames += 1
            self.encodedBytes += frame.annexB.count
            self.statsLock.unlock()
            self.sink.sendFrame(frame)
        }
    }

    func handle(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        encoder.encode(pixelBuffer: pixelBuffer, pts: pts)
    }

    func startStats(every seconds: Double, extra: (() -> String)? = nil) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mactv.stats"))
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.statsLock.lock()
            let frames = self.encodedFrames
            let bytes = self.encodedBytes
            self.statsLock.unlock()
            let now = Date()
            let dt = now.timeIntervalSince(self.lastStats.time)
            let fps = Double(frames - self.lastStats.frames) / dt
            let mbps = Double(bytes - self.lastStats.bytes) * 8 / dt / 1_000_000
            self.lastStats = (frames, bytes, now)
            var line = String(format: "encoded %.1f fps, %.2f Mbit/s", fps, mbps)
            if let extra { line += extra() }
            Log.info(line)
        }
        timer.resume()
        statsTimer = timer
    }

    func stop() {
        statsTimer?.cancel()
        encoder.flush()
        sink.stop()
    }
}
