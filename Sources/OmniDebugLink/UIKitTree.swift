#if canImport(UIKit)
import UIKit
import ObjectiveC

/// UIKit view-hierarchy snapshot shared by ui_traverse / find_objects /
/// view_component / wait_for / ui_click. SwiftUI content surfaces through its
/// hosting UIView: SwiftUI controls live in the hosting view's
/// accessibilityElements, not as subviews — those elements are flattened into
/// pseudo-nodes (path suffix `#a<i>`), so a SwiftUI view with
/// .accessibilityIdentifier() is findable and clickable like any UIKit view.
/// Snapshotting is synchronous and capped at 3000 nodes.
struct ViewNode {
    let view: UIView
    let axElement: NSObject? // accessibility pseudo-node target (SwiftUI etc.)
    let depth: Int
    let path: String
    let frameInWindow: CGRect? // window coords, points, top-left origin
    let type: String
    let identifier: String?
    let label: String?
    let text: String?
    let isHidden: Bool
    let alpha: CGFloat

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
        if let f = frameInWindow {
            d["rect"] = ["x": f.origin.x, "y": f.origin.y, "width": f.width, "height": f.height]
            d["center"] = [Int(f.midX.rounded()), Int(f.midY.rounded())]
        }
        return d
    }

    func center01(in windowBounds: CGRect?) -> [Double]? {
        guard let f = frameInWindow, let wb = windowBounds, wb.width > 0, wb.height > 0 else { return nil }
        return [Double(f.midX / wb.width), Double(f.midY / wb.height)]
    }
}

final class ViewTreeSnapshot {
    static let maxNodes = 3000
    private(set) var nodes: [ViewNode] = []
    private(set) var window: UIWindow?
    var windowBounds: CGRect? { window?.bounds }

    init() {
        guard let window = UIKitWindows.keyWindow() else { return }
        self.window = window
        walk(window, depth: 0, path: "0")
    }

    private func walk(_ view: UIView, depth: Int, path: String) {
        nodes.append(ViewNode(
            view: view,
            axElement: nil,
            depth: depth,
            path: path,
            frameInWindow: frameInWindow(view),
            type: String(describing: type(of: view)),
            identifier: view.accessibilityIdentifier,
            label: view.accessibilityLabel,
            text: ViewText.of(view),
            isHidden: view.isHidden,
            alpha: view.alpha))
        if nodes.count >= ViewTreeSnapshot.maxNodes { return }
        for (i, child) in view.subviews.enumerated() {
            if nodes.count >= ViewTreeSnapshot.maxNodes { break }
            walk(child, depth: depth + 1, path: "\(path)/\(i)")
        }
        // SwiftUI (and custom accessible containers) expose their controls as
        // accessibilityElements on the hosting view, not as subviews — flatten
        // them so key/text locators can reach SwiftUI content.
        if let elements = view.accessibilityElements, !elements.isEmpty {
            for (i, el) in elements.prefix(80).enumerated() {
                if nodes.count >= ViewTreeSnapshot.maxNodes { break }
                guard let obj = el as? NSObject else { continue }
                let ident = (obj as? UIAccessibilityIdentification)?.accessibilityIdentifier
                // UIAccessibility is an informal protocol — label/frame are
                // NSObject extension members, no protocol cast possible.
                let label = obj.accessibilityLabel
                var frame: CGRect?
                if let win = self.window {
                    // accessibilityFrame is in SCREEN points; UIWindow.frame is
                    // also in screen coords — offsetting gives window coords.
                    let f = obj.accessibilityFrame
                    frame = CGRect(x: f.origin.x - win.frame.origin.x,
                                   y: f.origin.y - win.frame.origin.y,
                                   width: f.width, height: f.height)
                }
                nodes.append(ViewNode(
                    view: view,
                    axElement: obj,
                    depth: depth + 1,
                    path: "\(path)#a\(i)",
                    frameInWindow: frame,
                    type: String(describing: type(of: obj)),
                    identifier: ident,
                    label: label,
                    text: nil,
                    isHidden: false,
                    alpha: view.alpha))
            }
        }
    }

    /// Per-node math isolated: a detached/animating view must not fail the whole dump.
    private func frameInWindow(_ view: UIView) -> CGRect? {
        guard let window else { return nil }
        guard view.window === window || view.window == nil else {
            return view.frame
        }
        return view.convert(view.bounds, to: window)
    }

    func node(atPath path: String) -> ViewNode? {
        nodes.first { $0.path == path }
    }

    /// Substring, case-insensitive locator — key (accessibilityIdentifier,
    /// the stable id, preferred), text (visible text/label), view_type (class
    /// name), + index to disambiguate. Returns nil when nothing matches.
    func locate(path: String?, key: String?, text: String?, viewType: String?, index: Int = 0) -> ViewNode? {
        if let path {
            if let n = node(atPath: path) { return n }
            return nil
        }
        var matched: [ViewNode] = nodes
        if let key, key.count > 0 {
            matched = matched.filter { $0.identifier?.localizedCaseInsensitiveContains(key) == true }
        }
        if let text, text.count > 0 {
            matched = matched.filter { node in
                let haystack = [node.text, node.label].compactMap { $0 }.joined(separator: " ")
                return haystack.localizedCaseInsensitiveContains(text)
            }
        }
        if let viewType, viewType.count > 0 {
            matched = matched.filter { $0.type.localizedCaseInsensitiveContains(viewType) }
        }
        guard index >= 0, index < matched.count else { return nil }
        return matched[index]
    }

    func hitTest(_ point: CGPoint) -> UIView? {
        window?.hitTest(point, with: nil)
    }

    /// SwiftUI hosting views materialize their accessibility tree only when
    /// an accessibility client is active. If we see a hosting view with zero
    /// flattened pseudo-nodes, the AI is told why (return-value hint, not a
    /// task-description essay).
    var swiftUIHint: String? {
        let hostingCount = nodes.filter { $0.type.contains("UIHostingView") }.count
        guard hostingCount > 0 else { return nil }
        let pseudoCount = nodes.filter { $0.axElement != nil }.count
        guard pseudoCount == 0 else { return nil }
        return "SwiftUI hosting view(s) present but their accessibility tree is empty: "
            + "SwiftUI materializes it only when an accessibility client is active. Fix: "
            + "on the Mac with the simulator run `xcrun simctl spawn booted defaults write "
            + "com.apple.Accessibility AXEnhancedUserInterfaceFeaturesEnabled 1`, then "
            + "restart the app (`xcrun simctl terminate booted <bundle-id> && xcrun simctl "
            + "launch booted <bundle-id>` — do both yourself if you have shell access; "
            + "otherwise ask the user). Enabling VoiceOver or connecting Accessibility "
            + "Inspector also works. UIKit views are unaffected."
    }
}

enum ViewText {
    /// Best-effort visible-text extraction, no reflection on the hot path.
    static func of(_ view: UIView) -> String? {
        if let label = view as? UILabel { return label.text }
        if let field = view as? UITextField { return field.text }
        if let tv = view as? UITextView { return tv.text }
        if let button = view as? UIButton { return button.currentTitle }
        return nil
    }
}

// MARK: - tasks

func registerUIKitTreeTasks() {
    let t = OmniDebugLink.tasks

    t.register(
        "ui_traverse",
        { task in
            let flat = task.boolOf("flat", def: true) ?? true
            let depthLimit = task.intOrNull("depth", min: 1, max: 60)
            let startPath = task.str("path")
            let tree = ViewTreeSnapshot()
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
            if flat {
                let wb = tree.windowBounds
                let list = nodes.map { node -> [String: Any] in
                    var d = node.dict
                    if let c01 = node.center01(in: wb) { d["center01"] = c01 }
                    return d
                }
                var out: [String: Any] = ["count": list.count, "flat": true, "nodes": list]
                if let hint = tree.swiftUIHint { out["hint"] = hint }
                return out
            } else {
                var byPath: [String: [String: Any]] = [:]
                for node in nodes.reversed() {
                    var d = node.dict
                    if let c01 = node.center01(in: tree.windowBounds) { d["center01"] = c01 }
                    var children: [[String: Any]] = []
                    for child in nodes where isDirectChild(child, of: node) {
                        if let cd = byPath[child.path] { children.append(cd) }
                    }
                    if !children.isEmpty { d["children"] = children }
                    byPath[node.path] = d
                }
                let root = nodes.first.flatMap { byPath[$0.path] } ?? [:] as [String: Any]
                return ["flat": false, "root": root]
            }
        },
        description:
            "Dump the UIKit view hierarchy of the foreground window. Default flat=true "
            + "returns a flat node list (depth/name/key/text/rect/center(px and 0..1 "
            + "normalized)/path, token-friendly); flat=false returns a nested tree. "
            + "rect/center are in window points with a TOP-LEFT origin. SwiftUI content "
            + "surfaces through its hosting view's accessibility tree (requires an "
            + "accessibility runtime to be active; give SwiftUI controls "
            + ".accessibilityIdentifier to address them). Optional path starts at a "
            + "node, depth limits levels below it. Capped at 3000 nodes.",
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
            let tree = ViewTreeSnapshot()
            var matched: [ViewNode] = []
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
                "swiftUIHint": tree.swiftUIHint ?? NSNull(),
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
            let tree = ViewTreeSnapshot()
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
            d["props"] = reflectProps(node.view)
            d["hasTapGesture"] = node.view.gestureRecognizers?.contains {
                $0 is UITapGestureRecognizer
            } ?? false
            return d
        },
        description:
            "Inspect one view: class, key/text, rect, plus a curated property dump "
            + "(Mirror reflection over simple-typed properties — text, alpha, state, "
            + "control values and the like). Locate by key / text / view_type (+index) "
            + "or exact path, same locators as ui_click.",
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
                let tree = ViewTreeSnapshot()
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

private func isDirectChild(_ candidate: ViewNode, of parent: ViewNode) -> Bool {
    guard let i = candidate.path.lastIndex(of: "/") else { return false }
    return String(candidate.path[candidate.path.startIndex..<i]) == parent.path
        && candidate.depth == parent.depth + 1
}

/// Property dump for view_component. Swift's Mirror sees only Swift stored
/// properties — UIKit state lives in ObjC ivars — so walk the ObjC runtime
/// property list up the superclass chain instead.
/// Reads go through respondsToSelector + perform (a plain method call), NEVER
/// value(forKey:) — KVC's undefined-key search crashed the app on real-device
/// testing (UITextField property internally KVCs into UITextInputTraits, which
/// raised valueForUndefinedKey; Swift cannot catch NSException).
func reflectProps(_ view: UIView, limit: Int = 40) -> [String: Any] {
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
            // responds-guard: skips properties declared but not implemented (these
            // are what sent KVC into uncatchable valueForUndefinedKey territory).
            guard view.responds(to: sel) else { continue }
            // Type encoding decides interpretation — an NSNumber 0 from KVC is
            // ambiguous between bool false and number 0 without it. It also gates
            // the KVC call itself: non-object encodings the accessor search can't
            // handle (SEL-typed NSControl.action on macOS) raise an uncatchable
            // valueForUndefinedKey NSException, so anything we can't consume is
            // skipped without touching KVC.
            guard let attrsC = property_getAttributes(list[i]) else { continue }
            let attrs = String(cString: attrsC)
            let typeChar = attrs.dropFirst().first.map { String($0) } ?? "@"
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
                out[name] = v // KVC already boxed scalars into NSNumber
            case "B", "c":
                out[name] = (v as? NSNumber)?.boolValue ?? v
            case "@":
                if let simple = simpleValue(v) { out[name] = simple }
            default:
                break
            }
        }
        clazz = class_getSuperclass(c)
    }
    if out.isEmpty { out["type"] = String(describing: type(of: view)) }
    return out
}

private func simpleValue(_ v: Any) -> Any? {
    switch v {
    case let s as String: return s.count > 200 ? nil : s
    case let b as Bool: return b
    case let n as NSNumber: return n
    default: return nil
    }
}
#endif
