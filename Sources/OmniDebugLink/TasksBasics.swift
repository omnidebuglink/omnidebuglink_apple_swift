import Foundation

func registerBasicTasks() {
    let t = OmniDebugLink.tasks

    t.register(
        "ping",
        { task in ["pong": true, "sentAt": task.payload["sentAt"] ?? NSNull()] },
        description:
            "Round-trip liveness probe; echoes sentAt back with pong=true.",
        payloadSchema:
            #"{"type":"object","properties":{"sentAt":{"type":"integer"}},"additionalProperties":false}"#)

    t.register(
        "echo",
        { task in task.payload },
        description:
            "Returns the payload unchanged. Useful for smoke-testing the relay loop.",
        payloadSchema:
            #"{"type":"object","additionalProperties":true}"#)

    t.register(
        "get_stats",
        { _ in
            [
                "libVersion": OmniDebugLink.libVersion,
                "appVersion": OmniDebugLink.appVersionValue,
                "platform": OmniDebugLink.platform,
                "osVersion": OmniDebugLink.osVersionString,
                "model": deviceModel,
                "uptimeMs": OmniDebugLink.uptimeMs,
                "tasksCount": OmniDebugLink.tasks.count,
                "actionsEnabled": OmniDebugLink.actionsEnabled,
                "connected": OmniDebugLink.state == .connected,
                "linkState": OmniDebugLink.state.rawValue,
            ] as [String: Any]
        },
        description:
            "Basic runtime stats: lib/app version, platform and OS version, device model, "
            + "uptime, task count, connection state.")
}

var deviceModel: String {
    var sys = utsname()
    uname(&sys)
    return withUnsafeBytes(of: &sys.machine) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}
