import Foundation

func registerPrefsTasks() {
    OmniDebugLink.tasks.register(
        "prefs",
        { task in
            let defaults = UserDefaults.standard
            let action = task.str("action") ?? ""
            switch action {
            case "get":
                guard let key = task.str("key") else {
                    throw TaskException("TASK_INVALID", "action=get requires key")
                }
                return ["key": key, "value": defaults.object(forKey: key) ?? NSNull()]
            case "set":
                guard let key = task.str("key") else {
                    throw TaskException("TASK_INVALID", "action=set requires key")
                }
                guard task.payload.keys.contains("value") else {
                    throw TaskException("TASK_INVALID", "action=set requires value")
                }
                let raw = task.payload["value"] ?? NSNull()
                let value = coerce(raw, type: task.str("value_type"))
                defaults.set(value, forKey: key)
                return ["key": key, "value": value]
            case "delete":
                guard let key = task.str("key") else {
                    throw TaskException("TASK_INVALID", "action=delete requires key")
                }
                defaults.removeObject(forKey: key)
                return ["key": key, "deleted": true]
            case "list":
                var out: [String: Any] = [:]
                for key in defaults.dictionaryRepresentation().keys.sorted()
                where !key.hasPrefix("NS") && !key.hasPrefix("Apple") && !key.hasPrefix("AK") {
                    out[key] = defaults.object(forKey: key) ?? NSNull()
                }
                return ["count": out.count, "prefs": out]
            default:
                throw TaskException("TASK_INVALID", "action must be get|set|delete|list")
            }
        },
        description:
            "UserDefaults get/set/delete/list. action is required (get|set|delete|list); "
            + "key is required for get/set/delete. set supports value_type coercion "
            + "(string|int|float|bool) — {\"value\":\"42\",\"value_type\":\"int\"} stores "
            + "int 42. Values are echoed back with their actual stored type.",
        payloadSchema:
            #"{"type":"object","properties":{"action":{"type":"string","enum":["get","set","delete","list"],"description":"required"},"key":{"type":"string"},"value":{},"value_type":{"type":"string","enum":["string","int","float","bool"]}},"required":["action"],"additionalProperties":false}"#)
}

private func coerce(_ raw: Any, type: String?) -> Any {
    switch type {
    case "int":
        if let n = raw as? NSNumber { return n.int64Value }
        if let s = raw as? String, let i = Int64(s) { return i }
    case "float":
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String, let d = Double(s) { return d }
    case "bool":
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            if s == "1" || s.lowercased() == "true" { return true }
            if s == "0" || s.lowercased() == "false" { return false }
        }
    case "string":
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
    default:
        break
    }
    return raw
}
