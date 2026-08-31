import Foundation

/// WebSocket link layer. One instance per `start()`; owns the connect loop,
/// heartbeat (55s ping), inbound watchdog (180s) and exponential backoff
/// (1s→30s). Close code 4000 = this token was replaced by a newer connection:
/// it permanently stops reconnecting (one token pair = one device seat —
/// reconnecting would ping-pong with the server's kicker forever).
final class LinkConnection: NSObject, URLSessionWebSocketDelegate {
    static let heartbeatMs: Int = 55_000
    static let watchdogMs: Int = 180_000
    static let backoffCapMs: Int = 30_000

    private let url: URL
    private let helloBuilder: () -> [String: Any]
    private let onTaskFrame: (_ requestId: String, _ type: String, _ payload: [String: Any]) -> Void
    private let onStateChange: (LinkState) -> Void

    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "omnidebuglink.link")
    private var stopped = false
    private var replaced = false
    private var connected = false
    private var backoffMs: Int = 1000
    private var nextPingAt: DispatchTime = .now()
    private var lastInboundAt: DispatchTime = .now()

    init(url: URL,
         helloBuilder: @escaping () -> [String: Any],
         onTaskFrame: @escaping (_ requestId: String, _ type: String, _ payload: [String: Any]) -> Void,
         onStateChange: @escaping (LinkState) -> Void) {
        self.url = url
        self.helloBuilder = helloBuilder
        self.onTaskFrame = onTaskFrame
        self.onStateChange = onStateChange
        super.init()
    }

    // MARK: lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.connect()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.teardownTimer()
            self.socket?.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            // Break the session→delegate retain so this connection can deinit.
            self.session.finishTasksAndInvalidate()
            self.session = nil
            self.onStateChange(.stopped)
        }
    }

    /// Force an immediate hello resend (used by `announce()` and on registry change).
    func sendHello() {
        queue.async { [weak self] in
            guard let self, let ws = self.socket, self.connected else { return }
            let hello = self.helloBuilder()
            self.send(["v": 1, "type": "hello",
                       "client": hello["client"] ?? [:],
                       "tasks": hello["tasks"] ?? []], on: ws)
        }
    }

    // MARK: connect loop

    private func connect() {
        if stopped || replaced { return }
        onStateChange(.connecting)
        let ws = session.webSocketTask(with: url)
        socket = ws
        lastInboundAt = .now()
        nextPingAt = .now() + .milliseconds(LinkConnection.heartbeatMs)
        ws.resume()
        receiveLoop(on: ws)
    }

    private func reconnect() {
        if stopped || replaced { return }
        teardownTimer()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        queue.asyncAfter(deadline: .now() + .milliseconds(backoffMs)) { [weak self] in
            guard let self, !self.stopped, !self.replaced else { return }
            self.connect()
        }
        backoffMs = min(backoffMs * 2, LinkConnection.backoffCapMs)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            guard let self, webSocketTask === self.socket else { return }
            self.connected = true
            self.backoffMs = 1000
            self.onStateChange(.connected)
            print("[OmniDebugLink] connected to \(self.url.host ?? "?")")
            let hello = self.helloBuilder()
            self.send(["v": 1, "type": "hello",
                       "client": hello["client"] ?? [:],
                       "tasks": hello["tasks"] ?? []], on: webSocketTask)
            self.startTimer()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [weak self] in
            guard let self, webSocketTask === self.socket else { return }
            if closeCode.rawValue == 4000 {
                self.handleReplacement()
                return
            }
            self.connected = false
            self.reconnect()
        }
    }

    /// Close code 4000 = this token's seat was taken over by a newer
    /// connection. Stop for good — reconnecting would ping-pong with the
    /// server's kicker forever (one token pair = one device seat).
    private func handleReplacement() {
        replaced = true
        connected = false
        teardownTimer()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onStateChange(.stopped)
        let message = "connection closed with code 4000: this token pair was replaced by a "
            + "newer connection (one token pair = one device seat). Reconnecting disabled; "
            + "give each device its own token pair."
        OmniDebugLink.logBuffer.record(message, level: .warning)
        print("[OmniDebugLink] \(message)")
    }

    // MARK: receive loop / heartbeat

    private func receiveLoop(on ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.queue.async {
                    guard ws === self.socket else { return }
                    self.connected = false
                    // Real-device lesson: the 4000 close code often surfaces HERE
                    // (receive fails) before/instead of the didCloseWith delegate —
                    // reading closeCode after the failure is the reliable spot.
                    if ws.closeCode.rawValue == 4000 {
                        self.handleReplacement()
                        return
                    }
                    OmniDebugLink.logBuffer.record(
                        "connection lost: \(error.localizedDescription) (closeCode=\(ws.closeCode.rawValue))",
                        level: .warning)
                    print("[OmniDebugLink] connection lost: \(error.localizedDescription) "
                        + "(closeCode=\(ws.closeCode.rawValue)), reconnecting")
                    self.reconnect()
                }
            case .success(let message):
                self.queue.async {
                    guard ws === self.socket else { return }
                    self.lastInboundAt = .now()
                    switch message {
                    case .string(let text):
                        self.handleFrame(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleFrame(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveLoop(on: ws)
                }
            }
        }
    }

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["v"] as? Int) == 1,
              let type = obj["type"] as? String else { return }
        switch type {
        case "pong":
            return // any inbound frame already stamped liveness
        case "task":
            guard let requestId = obj["requestId"] as? String,
                  let task = obj["task"] as? [String: Any],
                  let taskType = task["type"] as? String else { return }
            let payload = (task["payload"] as? [String: Any]) ?? [:]
            onTaskFrame(requestId, taskType, payload)
        default:
            break
        }
    }

    private func startTimer() {
        teardownTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        t.setEventHandler { [weak self] in
            guard let self, let ws = self.socket, self.connected, !self.stopped else { return }
            if DispatchTime.now() >= self.nextPingAt {
                self.send(["v": 1, "type": "ping"], on: ws)
                self.nextPingAt = .now() + .milliseconds(LinkConnection.heartbeatMs)
            }
            let idleMs = Double(DispatchTime.now().uptimeNanoseconds - self.lastInboundAt.uptimeNanoseconds) / 1_000_000
            if idleMs > Double(LinkConnection.watchdogMs) {
                OmniDebugLink.logBuffer.record(
                    "watchdog: no inbound traffic for \(Int(idleMs))ms, dropping connection", level: .warning)
                self.connected = false
                self.reconnect()
            }
        }
        t.resume()
        timer = t
    }

    private func teardownTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: result frames

    /// The ONLY result-frame constructors in this client (success frames must
    /// carry "ok":true — the relay treats a missing ok as failure).
    func sendResultOk(requestId: String, result: Any?) {
        queue.async { [weak self] in
            guard let self, let ws = self.socket else { return }
            self.send(["v": 1, "type": "result", "requestId": requestId,
                       "ok": true, "result": result ?? NSNull()], on: ws)
        }
    }

    func sendResultError(requestId: String, code: String, message: String) {
        queue.async { [weak self] in
            guard let self, let ws = self.socket else { return }
            self.send(["v": 1, "type": "result", "requestId": requestId,
                       "ok": false, "error": ["code": code, "message": message]], on: ws)
        }
    }

    private func send(_ frame: [String: Any], on ws: URLSessionWebSocketTask) {
        guard JSONSerialization.isValidJSONObject(frame),
              let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if let error {
                self?.queue.async {
                    OmniDebugLink.logBuffer.record("send failed: \(error.localizedDescription)", level: .warning)
                }
            }
        }
    }
}
