import Foundation
import Network

/// One TCP connection to the receiver. Video goes out; control messages come back.
/// Applies back-pressure by dropping non-keyframes when the socket stops draining, so latency
/// stays bounded on a bad Wi-Fi link instead of growing without limit.
final class StreamSender {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mactv.net", qos: .userInteractive)
    private var reader = MessageReader()
    private var pendingBytes = 0
    private var droppingUntilKeyframe = false
    private let maxPendingBytes: Int

    private(set) var sentFrames = 0
    private(set) var droppedFrames = 0
    private(set) var sentBytes = 0

    var onReady: (() -> Void)?
    var onFailed: ((Error) -> Void)?
    var onClosed: (() -> Void)?
    var onKeyframeNeeded: (() -> Void)?

    init(endpoint: NWEndpoint, maxPendingBytes: Int = 1_500_000) {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 5
        }
        connection = NWConnection(to: endpoint, using: params)
        self.maxPendingBytes = maxPendingBytes
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("connected to \(self.connection.endpoint)")
                self.onReady?()
            case .failed(let error):
                self.onFailed?(error)
            case .cancelled:
                self.onClosed?()
            case .waiting(let error):
                Log.info("waiting for network: \(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop()
    }

    func stop() {
        connection.cancel()
    }

    func sendMessage(type: MessageType, flags: MessageFlags = [], ptsMicros: UInt64 = 0, payload: Data = Data()) {
        let data = WireProtocol.encode(type: type, flags: flags, ptsMicros: ptsMicros, payload: payload)
        queue.async { self.enqueue(data) }
    }

    func sendVideo(_ frame: EncodedFrame) {
        queue.async {
            if self.pendingBytes > self.maxPendingBytes, !frame.isKeyframe {
                if !self.droppingUntilKeyframe {
                    self.droppingUntilKeyframe = true
                    Log.debug("socket backed up (\(self.pendingBytes) B pending); dropping until next keyframe")
                    self.onKeyframeNeeded?()
                }
                self.droppedFrames += 1
                return
            }
            if frame.isKeyframe {
                self.droppingUntilKeyframe = false
            } else if self.droppingUntilKeyframe {
                self.droppedFrames += 1
                return
            }
            let data = WireProtocol.encode(
                type: .videoFrame,
                flags: frame.isKeyframe ? [.keyframe] : [],
                ptsMicros: frame.ptsMicros,
                payload: frame.annexB)
            self.sentFrames += 1
            self.enqueue(data)
        }
    }

    /// Snapshot of counters, read on the network queue so the numbers are consistent.
    func stats() -> (frames: Int, dropped: Int, bytes: Int, pending: Int) {
        queue.sync { (sentFrames, droppedFrames, sentBytes, pendingBytes) }
    }

    private func enqueue(_ data: Data) {
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= data.count
            self.sentBytes += data.count
            if let error { Log.warn("send failed: \(error)") }
        })
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for (header, payload) in self.reader.append(data) {
                    self.handleControl(header, payload)
                }
            }
            if isComplete {
                Log.info("receiver closed the connection")
                self.connection.cancel()
                return
            }
            if let error {
                Log.debug("receive ended: \(error)")
                return
            }
            self.receiveLoop()
        }
    }

    private func handleControl(_ header: MessageHeader, _ payload: Data) {
        switch MessageType(rawValue: header.type) {
        case .helloAck:
            Log.info("receiver says: \(String(data: payload, encoding: .utf8) ?? "<non-utf8>")")
        case .requestKeyframe:
            Log.debug("receiver requested a keyframe")
            onKeyframeNeeded?()
        default:
            Log.debug("ignoring control message type \(header.type)")
        }
    }
}
