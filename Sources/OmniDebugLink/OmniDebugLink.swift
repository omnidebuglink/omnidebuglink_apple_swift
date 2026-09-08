import Foundation

public enum LinkState: String {
    case stopped
    case connecting
    case connected
}

/// OmniDebugLink client entry point.
///
/// ```swift
/// OmniDebugLink.start("wss://api.omnidebuglink.dev/ws?token=<clientToken>")
/// ```
///
/// One token pair = one device seat; if the link dies with close code 4000
/// (replaced by a newer connection) the client stops reconnecting for good —
/// give each device its own token pair.
public enum OmniDebugLink {
    public static let libVersion = "0.2.2"

    /// Relay endpoint (baked in; self-hosted relays can change this constant).
    public static let relayUrlString = "wss://api.omnidebuglink.dev/ws"

    /// Random per-process id (UUID) appended to the /ws URL as `&instance=`
    /// so the relay can tell this process's own reconnects apart from a
    /// foreign session taking over the token. Generated once per process;
    /// stable across reconnects and stop()/start() cycles.
    static let instanceId = UUID().uuidString

    public static let tasks = TaskRegistry()
    public static let logBuffer = LogBuffer()

    private static let lock = NSRecursiveLock()
    private static var _connection: LinkConnection?
    private static var _actionsEnabled = true
    private static var _state: LinkState = .stopped
    private static var _appVersion: String = "?"
    private static var startedAt: Date?
    private static var helloResendScheduled = false

    static let platform: String = {
        #if os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(iOS) && targetEnvironment(macCatalyst)
        return "catalyst"
        #else
        return "ios"
        #endif
    }()

    /// Master switch for write/action tasks. false = read-only observation
    /// mode; reported in hello (call `announce()` to push immediately).
    public static var actionsEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _actionsEnabled }
        set {
            lock.lock(); _actionsEnabled = newValue; lock.unlock()
            announce()
        }
    }

    public static var state: LinkState {
        lock.lock(); defer { lock.unlock() }; return _state
    }

    /// The app version reported in hello/get_stats.
    public static var appVersionValue: String {
        lock.lock(); defer { lock.unlock() }; return _appVersion
    }

    /// Milliseconds since `start()` (monotonic-ish, from a stored start date).
    public static var uptimeMs: Int64 {
        guard let startedAt else { return 0 }
        return Int64(Date().timeIntervalSince(startedAt) * 1000)
    }

    /// Connect to the relay and register the platform's built-in tasks.
    /// Safe to call once per app launch; re-`start()` after `stop()` is allowed.
    /// - Parameters:
    ///   - clientToken: device token minted in the console; the relay endpoint is
    ///     baked in (`relayUrlString`) so callers never build URLs.
    ///   - appVersion: reported in hello/get_stats (defaults to the bundle short version).
    public static func start(_ clientToken: String, appVersion: String? = nil) {
        lock.lock()
        let token = clientToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientToken
        guard let parsed = URL(string: relayUrlString + "?token=" + token + "&instance=" + instanceId) else {
            lock.unlock()
            logBuffer.record("start(): invalid relay url", level: .error)
            return
        }
        _appVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "?"
        _connection?.stop()
        startedAt = Date()
        tasks.onChanged = { scheduleHelloResend() }
        registerBuiltinsOnce()
        let conn = LinkConnection(
            url: parsed,
            helloBuilder: { buildHello() },
            onTaskFrame: { requestId, type, payload in dispatch(requestId, type, payload) },
            onStateChange: { s in
                lock.lock(); _state = s; lock.unlock()
            })
        _connection = conn
        lock.unlock()
        conn.start()
        logBuffer.record("OmniDebugLink \(libVersion) starting on \(platform)", level: .log)
    }

    public static func stop() {
        lock.lock()
        _connection?.stop()
        _connection = nil
        tasks.onChanged = nil
        lock.unlock()
    }

    /// Force an immediate hello resend (after toggling `actionsEnabled`,
    /// (re-)registering tasks, or anything else that changes capabilities).
    public static func announce() {
        _connection?.sendHello()
    }

    // MARK: logs / errors

    /// Forward a log line so it becomes visible to `read_logs` (Apple OSes
    /// expose no past-console API, so nothing is captured automatically).
    public static func recordLog(_ message: String, level: LogLevel = .log) {
        logBuffer.record(message, level: level)
    }

    public static func recordError(_ error: Error) {
        logBuffer.record("\(error)", level: .error, stack: Thread.callStackSymbols.joined(separator: "\n"))
    }

    /// Called by every write task; throws ACTIONS_DISABLED when the master switch is off.
    static func ensureActionsEnabled() throws {
        if !actionsEnabled {
            throw TaskException("ACTIONS_DISABLED",
                                "actionsEnabled=false (read-only observation mode)")
        }
    }

    // MARK: hello / dispatch

    static func buildHello() -> [String: Any] {
        let client: [String: Any] = [
            "platform": platform,
            "version": _appVersion,
            "libVersion": libVersion,
            "actionsEnabled": actionsEnabled,
            "osVersion": osVersionString,
        ]
        return ["client": client, "tasks": tasks.tasksJson()]
    }

    static let osVersionString: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    /// Coalesce the ~20 onChanged firings of builtin registration into one hello.
    private static func scheduleHelloResend() {
        lock.lock()
        if helloResendScheduled {
            lock.unlock()
            return
        }
        helloResendScheduled = true
        lock.unlock()
        DispatchQueue.main.async {
            lock.lock(); helloResendScheduled = false; lock.unlock()
            announce()
        }
    }

    /// Task dispatch: handlers run on the main actor (all UI-touching builtins
    /// require it; core tasks are cheap enough not to care) and may run
    /// concurrently — each replies with its own requestId.
    private static func dispatch(_ requestId: String, _ type: String, _ payload: [String: Any]) {
        Task { @MainActor in
            guard let handler = tasks.handler(of: type) else {
                _connection?.sendResultError(requestId: requestId, code: "UNKNOWN_TASK",
                                             message: "task type '\(type)' is not registered on this client")
                return
            }
            let request = TaskRequest(requestId: requestId, type: type, payload: payload)
            do {
                let result = try await handler(request)
                _connection?.sendResultOk(requestId: requestId, result: result)
            } catch let e as TaskException {
                _connection?.sendResultError(requestId: requestId, code: e.code, message: e.message)
            } catch {
                _connection?.sendResultError(requestId: requestId, code: "TASK_FAILED",
                                             message: "\(error)")
            }
        }
    }

    /// Register builtins exactly once per process.
    private static var builtinsRegistered = false
    static func registerBuiltinsOnce() {
        lock.lock()
        let already = builtinsRegistered
        builtinsRegistered = true
        lock.unlock()
        if already { return }
        registerBasicTasks()
        registerLogTasks()
        registerPrefsTasks()
        registerPerfTasks()
        registerStateTasks()
        #if canImport(UIKit)
        registerUIKitTreeTasks()
        registerUIKitActionTasks()
        registerUIKitScreenshotTasks()
        #elseif os(macOS)
        registerAppKitTreeTasks()
        registerAppKitActionTasks()
        registerAppKitScreenshotTasks()
        #endif
    }
}
