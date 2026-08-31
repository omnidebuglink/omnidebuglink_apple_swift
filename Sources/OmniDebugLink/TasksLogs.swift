import Foundation

func registerLogTasks() {
    OmniDebugLink.tasks.register(
        "read_logs",
        { task in
            OmniDebugLink.logBuffer.query(
                level: task.str("level"),
                contains: task.str("contains"),
                limit: task.intOrNull("limit", min: 1, max: 500),
                sinceMs: task.intOrNull("since_ms").map { Int64($0) })
        },
        description:
            "Apple-side logs collected by this SDK since app start (newest first). Apple "
            + "OSes expose no past-console API, so only logs the app forwards via "
            + "OmniDebugLink.recordLog/recordError plus uncaught NSExceptions are "
            + "captured — there is no history from before link start and no system log. "
            + "Filter with level (log|warning|error), contains, limit (1-500, default 50) "
            + "and since_ms.",
        payloadSchema:
            #"{"type":"object","properties":{"level":{"type":"string","enum":["log","warning","error"]},"contains":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":500,"default":50},"since_ms":{"type":"integer"}},"additionalProperties":false}"#)

    // Route uncaught NSExceptions into the buffer (start-time hook; a crash
    // still takes the process down afterwards — this is best-effort capture).
    NSSetUncaughtExceptionHandler { exception in
        OmniDebugLink.logBuffer.record(
            "uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "")",
            level: .error,
            stack: exception.callStackSymbols.joined(separator: "\n"))
    }
}
