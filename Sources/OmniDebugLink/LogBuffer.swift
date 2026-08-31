import Foundation

public enum LogLevel: String {
    case log
    case warning
    case error
}

/// Ring buffer (1000 entries) behind `read_logs`. Apple OSes have no API to
/// read past console output (OSLog is subscribe-only), so the buffer holds only
/// what the app forwards via `recordLog`/`recordError` plus uncaught
/// exceptions — same trade-off as the Unity/Flutter clients.
public final class LogBuffer {
    public struct Entry {
        let ts: Int64 // epoch ms
        let level: LogLevel
        let message: String
        let stack: String?
    }

    static let capacity = 1000
    static let maxMessageChars = 4096
    static let maxStackChars = 8192

    private var entries: [Entry] = []
    private let lock = NSLock()

    func record(_ message: String, level: LogLevel, stack: String? = nil) {
        let cappedMessage = String(message.prefix(LogBuffer.maxMessageChars))
        let cappedStack = stack.map { String($0.prefix(LogBuffer.maxStackChars)) }
        lock.lock()
        entries.append(Entry(ts: Int64(Date().timeIntervalSince1970 * 1000),
                             level: level, message: cappedMessage, stack: cappedStack))
        if entries.count > LogBuffer.capacity {
            entries.removeFirst(entries.count - LogBuffer.capacity)
        }
        lock.unlock()
    }

    /// `read_logs` body: newest first, filtered.
    /// - level: "log"|"warning"|"error"
    /// - contains: substring match (message + stack)
    /// - limit: 1...500, default 50
    /// - sinceMs: epoch ms lower bound
    func query(level: String?, contains: String?, limit: Int?, sinceMs: Int64?) -> [String: Any] {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        let wantLevel = level.flatMap { lvl in
            [LogLevel.log, .warning, .error].first { $0.rawValue == lvl }
        }
        var out: [[String: Any]] = []
        for e in snapshot.reversed() {
            if let wantLevel = wantLevel, e.level != wantLevel { continue }
            if let sinceMs = sinceMs, e.ts < sinceMs { continue }
            if let contains = contains, contains.count > 0 {
                let hay = e.message + (e.stack ?? "")
                if !hay.localizedCaseInsensitiveContains(contains) { continue }
            }
            var item: [String: Any] = ["ts": e.ts, "level": e.level.rawValue, "message": e.message]
            if let stack = e.stack { item["stack"] = stack }
            out.append(item)
            if out.count >= (limit ?? 50) { break }
        }
        return ["count": out.count, "logs": out]
    }
}
