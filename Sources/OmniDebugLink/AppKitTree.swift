#if os(macOS)
import AppKit
import ObjectiveC

/// NSView-hierarchy snapshot (same model as the UIKit line). AppKit frames
/// use a BOTTOM-LEFT origin — rects reported here are converted to a TOP-LEFT
/// origin (matching screenshots and the normalized coordinate space), so the
/// AI sees one consistent geometry across all Apple platforms.
struct NSNode {
    let view: NSView
    let depth: Int
    let path: String
    let frameTopLeft: CGRect? // window coords, points, TOP-LEFT origin
    let type: String
    let identifier: String?
    let label: String?
    let text: String?
    let isHidden: Bool

    var dict: [String: Any] {
        var d: [String: Any] = [
            "depth": depth,
            "name": type,
            "hidden": isHidden,
            "path": path,
        ]
        if let identifier, identifier.count > 0 { d["key"] = identifier }
        if let text { d["text"] = text }
        if let label, label.count > 0, label != text { d["label"] = label }
        if let f = frameTopLeft {
            d["rect"] = ["x": f.origin.x, "y": f.origin.y, "width": f.width, "height": f.height]
            d["center"] = [Int(f.midX.rounded()), Int(f.midY.rounded())]
        }
        return d
    }

    func center01(in windowBounds: CGRect?) -> [Double]? {
        guard let f = frameTopLeft, let wb = windowBounds, wb.width > 0, wb.height > 0 else { return nil }
        return [Double(f.midX / wb.width), Double(f.midY / wb.height)]
    }
}

final class NSViewTreeSnapshot {
    static let maxNodes = 3000
    private(set) var nodes: [NSNode] = []
    private(set) var window: NSWindow?
    var windowBounds: CGRect? { window?.contentView?.bounds }

    init() {
        guard let window = AppKitWindows.target() else { return }
        self.window = window
        if let root = window.contentView {
            walk(root, depth: 0, path: "0")
        }
    }

    private func walk(_ view: NSView, depth: Int, path: String) {
        nodes.append(NSNode(
            view: view,
            depth: depth,
            path: path,
            frameTopLeft: frameTopLeftInWindow(view),
            type: String(describing: type(of: view)),
            identifier: view.accessibilityIdentifier(),
            label: view.accessibilityLabel(),
            text: AppKitText.of(view),
            isHidden: view.isHidden))
        if nodes.count >= NSViewTreeSnapshot.maxNodes { return }
        for (i, child) in view.subviews.enumerated() {
            if nodes.count >= NSViewTreeSnapshot.maxNodes { break }
            walk(child, depth: depth + 1, path: "\(path)/\(i)")
        }
    }

    /// AppKit bottom-left → TOP-LEFT (in window coordinates).
    private func frameTopLeftInWindow(_ view: NSView) -> CGRect? {
        guard let content = window?.contentView else { return view.frame }
        let f = view.convert(view.bounds, to: nil)
        let h = content.bounds.height
        return CGRect(x: f.origin.x, y: h - f.origin.y - f.height, width: f.width, height: f.height)
    }

    func node(atPath path: String) -> NSNode? {
        nodes.first { $0.path == path }
    }

    func locate(path: String?, key: String?, text: String?, viewType: String?, index: Int = 0) -> NSNode? {
        if let path {
            return node(atPath: path)
        }
        var matched: [NSNode] = nodes
        if let key, key.count > 0 {
            matched = matched.filter { $0.identifier?.localizedCaseInsensitiveContains(key) == true }
        }
        if let text, text.count > 0 {
            matched = matched.filter { node in
                let hay = [node.text, node.label].compactMap { $0 }.joined(separator: " ")
                return hay.localizedCaseInsensitiveContains(text)
            }
        }
        if let viewType, viewType.count > 0 {
            matched = matched.filter { $0.type.localizedCaseInsensitiveContains(viewType) }
        }
        guard index >= 0, index < matched.count else { return nil }
        return matched[index]
    }
}

/// Key window first, else any visible window.
enum AppKitWindows {
    static func all() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible }
    }

    static func target() -> NSWindow? {
        NSApp.keyWindow ?? all().first
    }
}

enum AppKitText {
    static func of(_ view: NSView) -> String? {
        if let button = view as? NSButton { return button.title }
        if let field = view as? NSTextField {
            // Static labels are NSTextField too — only report editable/selectable
            // ones as "text inputs" but any field's stringValue is its text.
            return field.stringValue
        }
        if let tv = view as? NSTextView {
            return tv.string
        }
        return nil
    }
}

// MARK: - tasks

func registerAppKitTreeTasks() {
    let t = OmniDebugLink.tasks

    t.register(
        "ui_traverse",
        { task in
            let flat = task.boolOf("flat", def: true) ?? true
            let depthLimit = task.intOrNull("depth", min: 1, max: 60)
            let startPath = task.str("path")
            let tree = NSViewTreeSnapshot()
            guard !tree.nodes.isEmpty else {
                throw TaskException("TASK_FAILED", "no window/content view to traverse")
            }
            var nodes = tree.nodes
            if let startPath {
                guard let start = tree.node(atPath: startPath) else {
                    throw TaskException("NOT_FOUND", "no node at path \(startPath)")
                }
                nodes = nodes.filter { $0.path == start.path || $0.path.hasPrefix(start.path + "/") }
            }
            let startDepth = nodes.first?.depth ?? 0
            if let depthLimit {
                nodes = nodes.filter { $0.depth - startDepth < depthLimit }
            }
            let wb = tree.windowBounds
            if flat {
                let list = nodes.map { node -> [String: Any] in
                    var d = node.dict
                    if let c01 = node.center01(in: wb) { d["center01"] = c01 }
                    return d
                }
                return ["count": list.count, "flat": true, "nodes": list] as [String: Any]
            } else {
                var byPath: [String: [String: Any]] = [:]
                for node in nodes.reversed() {
                    var d = node.dict
                    if let c01 = node.center01(in: wb) { d["center01"] = c01 }
                    var children: [[String: Any]] = []
                    for child in nodes where child.path.hasPrefix(node.path + "/") {
                        let rest = String(child.path.dropFirst(node.path.count + 1))
                        if !rest.contains("/"), let cd = byPath[child.path] {
                            children.append(cd)
                        }
                    }
                    if !children.isEmpty { d["children"] = children }
                    byPath[node.path] = d
                }
                let root = nodes.first.flatMap { byPath[$0.path] } ?? [:] as [String: Any]
                return ["flat": false, "root": root] as [String: Any]
            }
        },
        description:
            "Dump the NSView hierarchy of the key window. Default flat=true returns a "
            + "flat node list (depth/name/key/text/rect/center(px and 0..1 "
            + "normalized)/path, token-friendly); flat=false returns a nested tree. "
            + "AppKit's bottom-left origin is converted to TOP-LEFT so geometry "
            + "matches screenshots and the other Apple platforms. SwiftUI content "
            + "appears through its NSHostingView. Optional path starts at a node, "
            + "depth limits levels below it. Capped at 3000 nodes.",
        payloadSchema:
            #"{"type":"object","properties":{"flat":{"type":"boolean","default":true},"path":{"type":"string","description":"exact node path to start from"},"depth":{"type":"integer","minimum":1,"maximum":60,"description":"max levels below the start node"}},"additionalProperties":false}"#)

    t.register(
        "find_objects",
        { task in
            let text = task.str("text")
            let key = task.str("key")
            let viewType = task.str("view_type")
            let limit = task.intOf("limit", def: 50, min: 1, max: 200)
            guard text != nil || key != nil || viewType != nil else {
                throw TaskException("TASK_INVALID",
                                    "provide at least one of: text / key / view_type")
            }
            let tree = NSViewTreeSnapshot()
            var matched: [NSNode] = []
            for node in tree.nodes {
                if let key, key.count > 0,
                   node.identifier?.localizedCaseInsensitiveContains(key) != true { continue }
                if let text, text.count > 0 {
                    let hay = [node.text, node.label].compactMap { $0 }.joined(separator: " ")
                    if !hay.localizedCaseInsensitiveContains(text) { continue }
                }
                if let viewType, viewType.count > 0,
                   !node.type.localizedCaseInsensitiveContains(viewType) { continue }
                matched.append(node)
                if matched.count >= limit { break }
            }
            let wb = tree.windowBounds
            let objects = matched.map { node -> [String: Any] in
                var d = node.dict
                if let c01 = node.center01(in: wb) { d["center01"] = c01 }
                return d
            }
            return [
                "count": objects.count,
                "objects": objects,
                "hint": "pass the same key/text/view_type (+index) straight to ui_click / view_component",
            ] as [String: Any]
        },
        description:
            "Find views by text / key (accessibilityIdentifier) / view_type — substrings, "
            + "case-insensitive, all given filters must match. Returns up to limit "
            + "(1-200, default 50) objects with rect, center and 0..1 normalized center01 "
            + "(TOP-LEFT origin, same coordinate space as tap_screen).",
        payloadSchema:
            #"{"type":"object","properties":{"text":{"type":"string"},"key":{"type":"string","description":"accessibilityIdentifier substring (preferred locator)"},"view_type":{"type":"string","description":"view class name substring"},"limit":{"type":"integer","minimum":1,"maximum":200,"default":50}},"additionalProperties":false}"#)

    t.register(
        "view_component",
        { task in
            let tree = NSViewTreeSnapshot()
            guard let node = tree.locate(path: task.str("path"),
                                         key: task.str("key"),
                                         text: task.str("text"),
                                         viewType: task.str("view_type"),
                                         index: task.intOf("index", def: 0, min: 0)) else {
                throw TaskException("NOT_FOUND",
                                    "no view matched the locator; try find_objects first")
            }
            var d = node.dict
            if let c01 = node.center01(in: tree.windowBounds) { d["center01"] = c01 }
            d["props"] = reflectNSProps(node.view)
            return d
        },
        description:
            "Inspect one view: class, key/text, rect (TOP-LEFT origin), plus a curated "
            + "property dump (Mirror reflection over simple-typed properties). Locate "
            + "by key / text / view_type (+index) or exact path, same locators as "
            + "ui_click.",
        payloadSchema:
            #"{"type":"object","properties":{"path":{"type":"string"},"key":{"type":"string"},"text":{"type":"string"},"view_type":{"type":"string"},"index":{"type":"integer","minimum":0,"default":0}},"additionalProperties":false}"#)

    t.register(
        "wait_for",
        { task in
            let key = task.str("key")
            let textContains = task.str("text_contains")
            let viewType = task.str("widget_type") ?? task.str("view_type")
            let path = task.str("path")
            let timeoutMs = task.intOf("timeout_ms", def: 10_000, min: 100, max: 60_000)
            let started = Date()
            while true {
                let tree = NSViewTreeSnapshot()
                let found = tree.locate(path: path, key: key, text: textContains,
                                        viewType: viewType) != nil
                if found {
                    return ["found": true,
                            "waitedMs": Int(Date().timeIntervalSince(started) * 1000)] as [String: Any]
                }
                let waitedMs = Int(Date().timeIntervalSince(started) * 1000)
                if waitedMs >= timeoutMs {
                    return ["found": false, "waitedMs": waitedMs] as [String: Any]
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        },
        description:
            "Poll every 200ms until a view matching the locator exists; returns "
            + "found=false on timeout instead of erroring. Locate by key / "
            + "text_contains / view_type / path.",
        payloadSchema:
            #"{"type":"object","properties":{"key":{"type":"string"},"text_contains":{"type":"string"},"view_type":{"type":"string"},"path":{"type":"string"},"timeout_ms":{"type":"integer","minimum":100,"maximum":60000,"default":10000}},"additionalProperties":false}"#)
}

/// Property dump for view_component — ObjC runtime over the superclass chain
/// (Swift's Mirror sees nothing on AppKit classes). See UIKitTree.reflectProps.
private func reflectNSProps(_ view: NSView, limit: Int = 40) -> [String: Any] {
    let blocklist = ["description", "debugDescription", "hash"]
    var out: [String: Any] = [:]
    var clazz: AnyClass? = type(of: view)
    while let c = clazz, out.count < limit {
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(c, &count) else { break }
        defer { free(list) }
        for i in 0..<Int(count) {
            guard out.count < limit else { break }
            let name = String(cString: property_getName(list[i]))
            if name.hasPrefix("_") || name.hasPrefix("ax") || blocklist.contains(name) { continue }
            if out[name] != nil { continue }
            let sel = NSSelectorFromString(name)
            guard view.responds(to: sel) else { continue }
            guard let attrsC = property_getAttributes(list[i]) else { continue }
            let attrs = String(cString: attrsC)
            let typeChar = attrs.dropFirst().first.map { String($0) } ?? "@"
            // Gate on the type encoding BEFORE touching KVC. macOS declares
            // non-object-typed properties that pass responds(to:) yet make
            // value(forKey:) raise valueForUndefinedKey (NSControl.action is
            // SEL-typed) — the NSException escapes the MainActor task and
            // wedges the whole dispatch pipeline (verified on-device: every
            // task after it goes silent, across reconnects).
            switch typeChar {
            case "f", "d", "i", "q", "l", "s", "I", "Q", "L", "S", "C",
                 "B", "c", "@":
                break
            default:
                continue
            }
            guard let v = view.value(forKey: name) else { continue }
            switch typeChar {
            case "f", "d", "i", "q", "l", "s", "I", "Q", "L", "S", "C":
                out[name] = v
            case "B", "c":
                out[name] = (v as? NSNumber)?.boolValue ?? v
            case "@":
                if let simple = simpleNSValue(v) { out[name] = simple }
            default:
                break
            }
        }
        clazz = class_getSuperclass(c)
    }
    if out.isEmpty { out["type"] = String(describing: type(of: view)) }
    return out
}

private func simpleNSValue(_ v: Any) -> Any? {
    switch v {
    case let s as String: return s.count > 200 ? nil : s
    case let b as Bool: return b
    case let n as NSNumber: return n
    default: return nil
    }
}
#endif
