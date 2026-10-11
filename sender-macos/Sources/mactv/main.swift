import Foundation
import CoreMedia
import Network

let usage = """
mactv — mirror this Mac's screen to the Android TV receiver

USAGE
  mactv list                                show capturable displays
  mactv discover [--seconds N]              find receivers on the LAN (Bonjour _mactvmirror._tcp)
  mactv send (--host IP | --name "TV") [options]
                                            capture a display and stream it
  mactv selftest (--host IP | --name "TV") [--width W --height H] [options]
                                            stream a synthetic test pattern (no screen permission needed)
  mactv record --out FILE.h264 [--seconds N] [options]
                                            capture to a raw H.264 file (check with ffprobe / ffplay)

OPTIONS
  --port N          receiver port (default 7000)
  --display N       display index from `mactv list` (default 0)
  --fps N           frame rate (default 30)
  --bitrate N       target bits per second (default 8000000)
  --max-width N     scale output to fit (default 1920)
  --max-height N    scale output to fit (default 1080)
  --no-cursor       hide the mouse cursor
  --verbose         chatty logs
"""

struct Args {
    let command: String
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ argv: [String]) {
        var rest = argv.dropFirst()
        command = rest.first ?? "help"
        rest = rest.dropFirst()
        var it = rest.makeIterator()
        while let a = it.next() {
            guard a.hasPrefix("--") else { continue }
            let key = String(a.dropFirst(2))
            if ["no-cursor", "verbose", "advertise"].contains(key) {
                flags.insert(key)
            } else if let v = it.next() {
                values[key] = v
            }
        }
    }

    func string(_ key: String) -> String? { values[key] }
    func int(_ key: String, _ fallback: Int) -> Int { values[key].flatMap(Int.init) ?? fallback }
    func double(_ key: String, _ fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    Log.info("error: " + message)
    exit(code)
}

/// Resolve --host/--name into an endpoint. --name browses Bonjour until the name shows up.
func resolveEndpoint(_ args: Args) -> NWEndpoint {
    let port = NWEndpoint.Port(rawValue: UInt16(args.int("port", Int(WireProtocol.defaultPort))))!
    if let host = args.string("host") {
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }
    if let name = args.string("name") {
        Log.info("looking for \"\(name)\" on the network…")
        let results = Discovery.browse(seconds: args.double("seconds", 8)) { $0.name == name }
        guard let match = results.first(where: { $0.name == name }) else {
            let names = results.map { "\"\($0.name)\"" }.joined(separator: ", ")
            fail("no receiver named \"\(name)\" found" + (names.isEmpty ? "" : " (saw: \(names))"))
        }
        return match.endpoint
    }
    fail("pass --host IP or --name \"TV name\"")
}

func makeSender(_ args: Args, encoder: H264Encoder) -> StreamSender {
    let sender = StreamSender(endpoint: resolveEndpoint(args))
    sender.onKeyframeNeeded = { encoder.requestKeyframe() }
    sender.onFailed = { error in fail("connection failed: \(error)") }
    sender.onClosed = {
        Log.info("connection closed")
        exit(0)
    }
    return sender
}

func installSignalHandler(_ cleanup: @escaping () -> Void) {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            Log.info("stopping…")
            cleanup()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

// MARK: - Commands

func commandList() async {
    do {
        let displays = try await ScreenCapturer.displays()
        for d in displays {
            let main = d.isMain ? "  (main)" : ""
            print("[\(d.index)] \(d.pixelWidth)×\(d.pixelHeight) px, \(d.display.width)×\(d.display.height) pt, id \(d.display.displayID)\(main)")
        }
    } catch {
        fail(describeCaptureError(error))
    }
}

func commandDiscover(_ args: Args) {
    let seconds = args.double("seconds", 3)
    Log.info("browsing for \(WireProtocol.serviceType) for \(Int(seconds)) s…")
    let found = Discovery.browse(seconds: seconds)
    if found.isEmpty {
        print("no receivers found. Is the TV app running and on the same Wi-Fi?")
    }
    for f in found {
        print("\"\(f.name)\"  →  mactv send --name \"\(f.name)\"")
    }
}

func commandSend(_ args: Args) async {
    let capturer = ScreenCapturer()
    var options = ScreenCapturer.Options()
    options.displayIndex = args.int("display", 0)
    options.fps = args.int("fps", 30)
    options.maxWidth = args.int("max-width", 1920)
    options.maxHeight = args.int("max-height", 1080)
    options.showsCursor = !args.flag("no-cursor")

    // Need the output size before creating the encoder: start capture first, frames are
    // buffered by the pipeline closure below until the encoder exists.
    let pipeline = Locked<Pipeline?>(nil)
    capturer.onFrame = { pb, pts in
        pipeline.get()?.handle(pixelBuffer: pb, pts: pts)
    }
    capturer.onStopped = { _ in exit(2) }

    do {
        try await capturer.start(options: options)
    } catch {
        fail(describeCaptureError(error))
    }

    let encoder: H264Encoder
    do {
        encoder = try H264Encoder(config: .init(
            width: capturer.outputWidth, height: capturer.outputHeight,
            fps: options.fps, bitrate: args.int("bitrate", 8_000_000)))
    } catch {
        fail("\(error)")
    }
    Log.info("encoder: H.264 \(encoder.config.width)×\(encoder.config.height), \(encoder.config.bitrate / 1000) kbit/s, low-latency rate control \(encoder.usingLowLatencyRateControl ? "on" : "off")")

    let sender = makeSender(args, encoder: encoder)
    let sink = NetworkSink(sender: sender)
    let p = Pipeline(encoder: encoder, sink: sink)
    sender.onReady = {
        sink.sendHello(HelloInfo(name: Host.current().localizedName ?? "Mac",
                                 width: encoder.config.width, height: encoder.config.height, fps: options.fps))
        encoder.requestKeyframe()
        pipeline.set(p)
        p.startStats(every: 2) {
            let s = sender.stats()
            return ", sent \(s.frames), dropped \(s.dropped), \(s.pending / 1000) kB queued"
        }
    }
    installSignalHandler {
        p.stop()
        Task { await capturer.stop() }
    }
    sender.start()
}

func commandSelftest(_ args: Args) {
    let width = args.int("width", 1280)
    let height = args.int("height", 720)
    let fps = args.int("fps", 30)
    let source = SyntheticSource(width: width, height: height, fps: fps)
    let encoder: H264Encoder
    do {
        encoder = try H264Encoder(config: .init(width: source.width, height: source.height, fps: fps, bitrate: args.int("bitrate", 6_000_000)))
    } catch {
        fail("\(error)")
    }
    Log.info("selftest: \(source.width)×\(source.height) @ \(fps) fps, low-latency rate control \(encoder.usingLowLatencyRateControl ? "on" : "off")")

    let sender = makeSender(args, encoder: encoder)
    let sink = NetworkSink(sender: sender)
    let p = Pipeline(encoder: encoder, sink: sink)
    source.onFrame = { pb, pts in p.handle(pixelBuffer: pb, pts: pts) }
    sender.onReady = {
        sink.sendHello(HelloInfo(name: "mactv selftest", width: source.width, height: source.height, fps: fps))
        encoder.requestKeyframe()
        source.start()
        p.startStats(every: 2) {
            let s = sender.stats()
            return ", sent \(s.frames), dropped \(s.dropped), \(s.pending / 1000) kB queued"
        }
    }
    installSignalHandler {
        source.stop()
        p.stop()
    }
    sender.start()
}

func commandRecord(_ args: Args) async {
    guard let out = args.string("out") else { fail("record needs --out FILE.h264") }
    let seconds = args.double("seconds", 5)
    let capturer = ScreenCapturer()
    var options = ScreenCapturer.Options()
    options.displayIndex = args.int("display", 0)
    options.fps = args.int("fps", 30)
    options.maxWidth = args.int("max-width", 1920)
    options.maxHeight = args.int("max-height", 1080)
    options.showsCursor = !args.flag("no-cursor")

    let pipeline = Locked<Pipeline?>(nil)
    capturer.onFrame = { pb, pts in
        pipeline.get()?.handle(pixelBuffer: pb, pts: pts)
    }
    do {
        try await capturer.start(options: options)
    } catch {
        fail(describeCaptureError(error))
    }
    let sink: FileSink
    let encoder: H264Encoder
    do {
        sink = try FileSink(path: out)
        encoder = try H264Encoder(config: .init(
            width: capturer.outputWidth, height: capturer.outputHeight,
            fps: options.fps, bitrate: args.int("bitrate", 8_000_000)))
    } catch {
        fail("\(error)")
    }
    let p = Pipeline(encoder: encoder, sink: sink)
    pipeline.set(p)
    p.startStats(every: 1)
    Log.info("recording \(Int(seconds)) s to \(out)…")

    let finish = {
        pipeline.set(nil)
        p.stop()
        Log.info("wrote \(sink.frames) frames (\(sink.keyframes) keyframes), \(sink.bytes / 1000) kB to \(out)")
    }
    installSignalHandler {
        finish()
        Task { await capturer.stop() }
    }
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    await capturer.stop()
    finish()
    exit(0)
}

// MARK: - Entry

let args = Args(CommandLine.arguments)
Log.verbose = args.flag("verbose")

switch args.command {
case "list":
    Task { await commandList(); exit(0) }
case "discover":
    commandDiscover(args)
    exit(0)
case "send":
    Task { await commandSend(args) }
case "selftest":
    commandSelftest(args)
case "record":
    Task { await commandRecord(args) }
case "help", "--help", "-h":
    print(usage)
    exit(0)
default:
    print(usage)
    exit(64)
}
dispatchMain()
