import Foundation

/// A task frame dispatched by the relay. Payload values are decoded JSON
/// (nested `Any`) — always read them through the typed accessors below.
public struct TaskRequest {
    public let requestId: String
    public let type: String
    public let payload: [String: Any]

    public init(requestId: String, type: String, payload: [String: Any]) {
        self.requestId = requestId
        self.type = type
        self.payload = payload
    }

    public func str(_ key: String) -> String? {
        guard let v = payload[key] else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// Optional int without validation; use `intOf` when clamping matters.
    public func intOrNull(_ key: String, min minValue: Int? = nil, max maxValue: Int? = nil) -> Int? {
        guard let v = payload[key] else { return nil }
        if let i = v as? Int { return clamp(i, min: minValue, max: maxValue) }
        if let n = v as? NSNumber { return clamp(n.intValue, min: minValue, max: maxValue) }
        if let s = v as? String, let i = Int(s) { return clamp(i, min: minValue, max: maxValue) }
        return nil
    }

    public func intOf(_ key: String, def: Int? = nil, min minValue: Int? = nil, max maxValue: Int? = nil) -> Int {
        intOrNull(key, min: minValue, max: maxValue) ?? def ?? 0
    }

    public func numOf(_ key: String) -> Double? {
        guard let v = payload[key] else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let d = Double(s) { return d }
        return nil
    }

    public func boolOf(_ key: String, def: Bool = false) -> Bool? {
        guard let v = payload[key] else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return def
    }

    private func clamp(_ i: Int, min minValue: Int?, max maxValue: Int?) -> Int {
        var r = i
        if let minValue = minValue, r < minValue { r = minValue }
        if let maxValue = maxValue, r > maxValue { r = maxValue }
        return r
    }
}

/// The only failure channel for task handlers. The code/message go verbatim
/// into the error result frame.
public struct TaskException: Error {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// Handlers are MainActor-isolated: dispatch already runs them on the main
/// actor, and UI frameworks (UIKit/AppKit) require main-actor access for most
/// properties — typing it here keeps every handler body free of `await` hops.
public typealias TaskHandler = @MainActor (TaskRequest) async throws -> Any?

/// Task registry — the data source of the `hello` capabilities list.
/// Register/unregister from any thread; changes coalesce a hello resend.
public final class TaskRegistry {
    struct Spec {
        let type: String
        let handler: TaskHandler
        let description: String?
        let payloadSchema: Any?
    }

    private var specs: [String: Spec] = [:]
    private let lock = NSLock()

    /// Fired on every register/unregister; owner coalesces into one hello resend.
    public var onChanged: (() -> Void)?

    public func register(_ type: String,
                         _ handler: @escaping TaskHandler,
                         description: String? = nil,
                         payloadSchema: Any? = nil) {
        lock.lock()
        specs[type] = Spec(type: type, handler: handler,
                           description: description, payloadSchema: payloadSchema)
        lock.unlock()
        onChanged?()
    }

    public func unregister(_ type: String) {
        lock.lock(); specs.removeValue(forKey: type); lock.unlock()
        onChanged?()
    }

    public func has(_ type: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return specs[type] != nil
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return specs.count
    }

    func handler(of type: String) -> TaskHandler? {
        lock.lock(); defer { lock.unlock() }
        return specs[type]?.handler
    }

    /// `tasks` array of the hello frame. A string payloadSchema is decoded
    /// to a JSON object when possible (best-effort, raw string kept if invalid).
    func tasksJson() -> [[String: Any]] {
        lock.lock()
        let all = specs.values.sorted { $0.type < $1.type }
        lock.unlock()
        return all.map { spec in
            var entry: [String: Any] = ["type": spec.type]
            if let d = spec.description { entry["description"] = d }
            if let schema = spec.payloadSchema {
                if let s = schema as? String,
                   let data = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) {
                    entry["payloadSchema"] = obj
                } else {
                    entry["payloadSchema"] = schema
                }
            }
            return entry
        }
    }
}
