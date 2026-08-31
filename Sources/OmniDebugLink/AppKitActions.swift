#if os(macOS)
import AppKit
import CoreGraphics

/// In-process event-level injection: synthetic NSEvents are constructed with
/// the target window's number and fed to NSApp.sendEvent, so AppKit routes
/// them exactly like real input — no accessibility permission needed (events
/// never leave the process).
///
/// Verified dead end (macOS 12.5 Intel, real device): CGEventPostToPid events
/// never reach the app's event loop at all (local NSEvent monitor saw nothing,
/// warp or no warp) — don't go back to CGEvent here.

private let coordDoc =
    "Coordinates are floats 0..1, origin at the TOP-LEFT corner of the key "
    + "window. For a pixel (px, py) in a returned screenshot of size W×H "
    + "(image origin top-left): x=(px+0.5)/W, y=(py+0.5)/H (no vertical flip)."

/// Post a synthetic mouse event into this process. The point is in the
/// WINDOW's coordinate space (bottom-left origin), i.e. what
/// `view.convert(_, to: nil)` produces. Queued via NSApp.postEvent (NOT
/// sendEvent): the runloop dispatches it like real input, so control
/// tracking loops (button mouseDown waits for the queued mouseUp) see the
/// full sequence — sendEvent dispatches synchronously, bypassing the queue,
/// which left buttons highlighted but never fired their action.
private func postMouseEvent(_ kind: NSEvent.EventType, at windowPoint: CGPoint,
                            in window: NSWindow, clickCount: Int = 1) {
    guard let event = NSEvent.mouseEvent(with: kind,
                                         location: windowPoint,
                                         modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber,
                                         context: nil,
                                         eventNumber: 0,
                                         clickCount: clickCount,
                                         pressure: kind == .leftMouseDragged ? 0.5 : 1.0) else { return }
    NSApp.postEvent(event, atStart: false)
}

/// Key codes (HID usage) + characters for the send_key set.
private let keySpecs: [String: (code: UInt16, chars: String)] = [
    "enter": (36, "\r"), "return": (36, "\r"),
    "tab": (48, "\t"),
    "space": (49, " "),
    "escape": (53, "\u{1b}"),
    "backspace": (51, "\u{7f}"), "del": (51, "\u{7f}"),
]

private func postKeyEvent(_ spec: (code: UInt16, chars: String), keyDown: Bool, in window: NSWindow) {
    guard let event = NSEvent.keyEvent(with: keyDown ? .keyDown : .keyUp,
                                       location: .zero,
                                       modifierFlags: [],
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber,
                                       context: nil,
                                       characters: keyDown ? spec.chars : "",
                                       charactersIgnoringModifiers: keyDown ? spec.chars : "",
                                       isARepeat: false,
                                       keyCode: spec.code) else { return }
    NSApp.postEvent(event, atStart: false)
}

private func locateForAction(_ task: TaskRequest) throws -> NSNode {
    let tree = NSViewTreeSnapshot()
    guard let node = tree.locate(path: task.str("path"),
                                 key: task.str("key"),
                                 text: task.str("text"),
                                 viewType: task.str("view_type"),
                                 index: task.intOf("index", def: 0, min: 0)) else {
        throw TaskException("NOT_FOUND",
                            "no view matched the locator; try find_objects first")
    }
    return node
}

/// Normalized (0..1, top-left) point in the key window → AppKit window point.
private func windowPoint(x: Double, y: Double, in window: NSWindow) -> CGPoint {
    let b = window.contentView?.bounds ?? .zero
    // AppKit window coords are bottom-left; normalized y is top-left.
    return CGPoint(x: b.width * CGFloat(x), y: b.height * CGFloat(1 - y))
}

func registerAppKitActionTasks() {
    let t = OmniDebugLink.tasks

    t.register(
        "ui_click",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            let node = try locateForAction(task)
            // NSControl.performClick is the direct programmatic click — better
            // fidelity than a synthetic mouse event for controls.
            if let control = node.view as? NSControl {
                control.performClick(nil)
                return [
                    "executed": true,
                    "method": "NSControl.performClick",
                    "target": node.type,
                    "key": node.identifier ?? NSNull(),
                    "text": node.text ?? NSNull(),
                    "path": node.path,
                ] as [String: Any]
            }
            if let window = node.view.window {
                let center = node.view.convert(node.view.bounds.center, to: nil)
                postMouseEvent(.leftMouseDown, at: center, in: window)
                postMouseEvent(.leftMouseUp, at: center, in: window)
                return [
                    "executed": true,
                    "method": "NSEvent click at view center",
                    "target": node.type,
                    "key": node.identifier ?? NSNull(),
                    "text": node.text ?? NSNull(),
                    "path": node.path,
                ] as [String: Any]
            }
            return ["executed": false, "reason": "view is not in a window",
                    "target": node.type, "path": node.path] as [String: Any]
        },
        description:
            "Click a view: NSControl targets get performClick() (direct programmatic "
            + "click); anything else gets a synthetic mouse click at its center, "
            + "injected into this process. Locate by key / text / view_type (substrings, "
            + "case-insensitive) + index, or exact path; finder and click run "
            + "atomically in one call. Prefer key. Use tap_screen to click by "
            + "normalized coordinates instead.",
        payloadSchema:
            #"{"type":"object","properties":{"path":{"type":"string","description":"exact node path (fallback; prefer key)"},"key":{"type":"string","description":"accessibilityIdentifier substring (preferred locator)"},"text":{"type":"string","description":"visible text substring"},"view_type":{"type":"string","description":"view class name substring"},"index":{"type":"integer","minimum":0,"default":0,"description":"nth match when several views match"}},"additionalProperties":false}"#)

    t.register(
        "tap_screen",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            guard let x = task.numOf("x"), let y = task.numOf("y"),
                  x >= 0, x <= 1, y >= 0, y <= 1 else {
                throw TaskException("TASK_INVALID", "x and y are required and must be within 0..1")
            }
            guard let window = AppKitWindows.target() else {
                throw TaskException("TASK_FAILED", "no window available")
            }
            let local = windowPoint(x: x, y: y, in: window)
            let base = window.contentView?.convert(local, to: nil) ?? local
            postMouseEvent(.leftMouseDown, at: base, in: window)
            postMouseEvent(.leftMouseUp, at: base, in: window)
            let b = window.contentView?.bounds ?? .zero
            return [
                "executed": true,
                "method": "NSEvent click (in-process)",
                "x": x,
                "y": y,
                "px": Int(local.x.rounded()),
                "py": Int((b.height - local.y).rounded()), // top-left px for AI convenience
                "screen": ["width": Int(b.width.rounded()), "height": Int(b.height.rounded())],
            ] as [String: Any]
        },
        description:
            "Mouse click at normalized coordinates, injected into this process as a "
            + "synthetic NSEvent (no accessibility permission needed; the physical "
            + "cursor does not move). " + coordDoc
            + " Returns the resolved point position and window size.",
        payloadSchema:
            #"{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":1,"description":"horizontal position, 0=left, 1=right"},"y":{"type":"number","minimum":0,"maximum":1,"description":"vertical position, 0=top, 1=bottom"}},"required":["x","y"],"additionalProperties":false}"#)

    t.register(
        "swipe",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            let x1 = task.numOf("x1"), y1 = task.numOf("y1")
            let x2 = task.numOf("x2"), y2 = task.numOf("y2")
            guard let x1, let y1, let x2, let y2 else {
                throw TaskException("TASK_INVALID", "x1/y1/x2/y2 are required")
            }
            let durationMs = task.intOf("duration_ms", def: 300, min: 50, max: 3000)
            guard let window = AppKitWindows.target() else {
                throw TaskException("TASK_FAILED", "no window available")
            }
            // On the Mac, dragging with the LEFT BUTTON selects/rubber-bands —
            // scrolling comes from scrollWheel events. Synthetic scroll events
            // can't be routed in-process (NSEvent has no scroll factory with a
            // windowNumber on this SDK; CGEvent-built ones get dropped before
            // dispatch — both verified on-device). So swipe = programmatic
            // scroll of the NSScrollView under the start point, animated over
            // duration_ms (same approach as the iOS line's programmatic
            // scroll; the mechanism is reported honestly in the result).
            let b = window.contentView?.bounds ?? .zero
            let from = windowPoint(x: x1, y: y1, in: window)
            guard let hit = window.contentView?.hitTest(from),
                  let scrollView = enclosingScrollView(hit) else {
                return ["executed": false,
                        "reason": "no scroll view under the start point",
                        "target": "content"] as [String: Any]
            }
            let clip = scrollView.contentView
            let docH = scrollView.documentView?.bounds.height ?? 0
            let maxY = max(0, docH - clip.bounds.height)
            let origin = clip.bounds.origin
            // NSClipView origin is bottom-left (y=0 = top of document); finger
            // up (y2 < y1) = forward = origin.y increases.
            let targetY = min(maxY, max(0, origin.y + (b.height * CGFloat(y1 - y2))))
            let steps = max(2, durationMs / 16)
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                clip.scroll(to: NSPoint(x: origin.x,
                                        y: origin.y + (targetY - origin.y) * t))
                if i < steps {
                    try await Task.sleep(nanoseconds: 16_000_000)
                }
            }
            return [
                "executed": true,
                "method": "programmatic scroll of NSScrollView",
                "scrolledTo": ["y": targetY],
                "from": [Int(from.x.rounded()), Int(from.y.rounded())],
                "durationMs": durationMs,
            ] as [String: Any]
        },
        description:
            "Scroll the scroll view under (x1,y1): programmatic scroll animated "
            + "over duration_ms 50-3000 (default 300). Finger up (y2 < y1) "
            + "scrolls content forward; the actual mechanism is reported in the "
            + "result. " + coordDoc,
        payloadSchema:
            #"{"type":"object","properties":{"x1":{"type":"number","minimum":0,"maximum":1},"y1":{"type":"number","minimum":0,"maximum":1},"x2":{"type":"number","minimum":0,"maximum":1},"y2":{"type":"number","minimum":0,"maximum":1},"duration_ms":{"type":"integer","minimum":50,"maximum":3000,"default":300}},"required":["x1","y1","x2","y2"],"additionalProperties":false}"#)

    t.register(
        "long_press",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            let durationMs = task.intOf("duration_ms", def: 800, min: 200, max: 5000)
            guard let window = AppKitWindows.target() else {
                throw TaskException("TASK_FAILED", "no window available")
            }
            var targetPoint: CGPoint?
            if let x = task.numOf("x"), let y = task.numOf("y") {
                let local = windowPoint(x: x, y: y, in: window)
                targetPoint = window.contentView?.convert(local, to: nil) ?? local
            } else if let node = try? locateForAction(task) {
                targetPoint = node.view.convert(node.view.bounds.center, to: nil)
            }
            guard let base = targetPoint else {
                throw TaskException("NOT_FOUND",
                                    "provide x/y coordinates or a locator (key/text/view_type/path)")
            }
            postMouseEvent(.leftMouseDown, at: base, in: window)
            // Keep the drag pump alive during the hold so recognizers see a
            // live (not stale) press.
            let steps = max(1, durationMs / 100)
            for _ in 0..<steps {
                try await Task.sleep(nanoseconds: 100_000_000)
                postMouseEvent(.leftMouseDragged, at: base, in: window)
            }
            postMouseEvent(.leftMouseUp, at: base, in: window)
            return ["executed": true,
                    "method": "NSEvent press-hold-release (in-process)",
                    "durationMs": durationMs,
                    "at": [Int(base.x.rounded()), Int(base.y.rounded())]] as [String: Any]
        },
        description:
            "Press-hold-release at x/y (normalized 0..1) or at a locator "
            + "(key/text/view_type/path), duration_ms 200-5000 (default 800), "
            + "injected into this process as synthetic NSEvents.",
        payloadSchema:
            #"{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1},"duration_ms":{"type":"integer","minimum":200,"maximum":5000,"default":800},"key":{"type":"string"},"text":{"type":"string"},"view_type":{"type":"string"},"path":{"type":"string"}},"additionalProperties":false}"#)

    t.register(
        "input_text",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            guard let text = task.str("text") else {
                throw TaskException("TASK_INVALID", "text (the value to type) is required")
            }
            // `text` is the VALUE being typed, not a locator — locate by
            // key/view_type/path, or fall back to the field editor / first
            // responder.
            var field = locateTextInput(task)
            if field == nil,
               task.str("key") == nil, task.str("view_type") == nil, task.str("path") == nil,
               let responder = AppKitWindows.target()?.firstResponder {
                field = responder as? NSTextView ?? responder as? NSTextField
            }
            guard let view = field else {
                throw TaskException("NOT_FOUND",
                                    "no text field matched the locator and no first "
                                    + "responder is a text input; provide key/view_type/path")
            }
            if applyNSText(view, text) {
                return ["executed": true,
                        "target": String(describing: type(of: view)),
                        "text": text] as [String: Any]
            }
            throw TaskException("TASK_FAILED",
                                "located view \(type(of: view)) is not a text input")
        },
        description:
            "Set text on a text field: locate by key / view_type / path, or omit "
            + "locators to use the currently focused input. The `text` argument is "
            + "the value being typed, not a locator. Setting fires the normal change "
            + "notifications (controlTextDidChange / action), so bound targets update.",
        payloadSchema:
            #"{"type":"object","properties":{"text":{"type":"string","description":"the value to type"},"key":{"type":"string"},"view_type":{"type":"string"},"path":{"type":"string"}},"required":["text"],"additionalProperties":false}"#)

    t.register(
        "send_key",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            guard let key = task.str("key") else {
                throw TaskException("TASK_INVALID", "key is required")
            }
            guard let spec = keySpecs[key] else {
                throw TaskException("TASK_INVALID",
                                    "key must be one of enter|return|tab|space|escape|backspace")
            }
            guard let window = AppKitWindows.target() else {
                throw TaskException("TASK_FAILED", "no window available")
            }
            postKeyEvent(spec, keyDown: true, in: window)
            postKeyEvent(spec, keyDown: false, in: window)
            return ["executed": true, "key": key,
                    "method": "NSEvent keyDown+keyUp (in-process)"] as [String: Any]
        },
        description:
            "Send a key event into this process as a synthetic NSEvent: "
            + "enter/return, tab, space, escape, backspace. Goes to the key "
            + "window's first responder.",
        payloadSchema:
            #"{"type":"object","properties":{"key":{"type":"string","enum":["enter","return","tab","space","escape","backspace","del"]}},"required":["key"],"additionalProperties":false}"#)

    t.register(
        "set_component",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            guard let values = task.payload["values"] as? [String: Any], !values.isEmpty else {
                throw TaskException("TASK_INVALID",
                                    "values object is required, e.g. {\"scroll_to_end\":true}")
            }
            let node = try locateForAction(task)
            let view = node.view
            var applied: [String: Any] = [:]
            var unsupported: [String] = []
            for (op, arg) in values {
                switch op {
                case "text":
                    if let s = arg as? String, applyNSText(view, s) {
                        applied[op] = true
                    } else {
                        unsupported.append(op)
                    }
                case "checked":
                    let on: Bool
                    if let b = arg as? Bool {
                        on = b
                    } else if let n = arg as? NSNumber {
                        on = n.boolValue
                    } else if let s = arg as? String {
                        on = s == "1" || s.lowercased() == "true"
                    } else {
                        unsupported.append(op)
                        continue
                    }
                    // NSButton has native `state` (NSSwitch does not — NSControl
                    // base class lacks it). For anything else that responds to
                    // setState:, fall back to KVC.
                    if let button = view as? NSButton {
                        button.state = on ? .on : .off
                        if let action = button.action, let target = button.target as? NSObject {
                            _ = target.perform(action, with: button)
                        }
                        applied[op] = button.state == .on
                    } else if view.responds(to: NSSelectorFromString("setState:")) {
                        view.setValue(on ? 1 : 0, forKey: "state")
                        applied[op] = true
                    } else {
                        unsupported.append(op)
                    }
                case "scroll_offset":
                    if let clip = enclosingClipView(view), let dict = arg as? [String: Any] {
                        let origin = NSPoint(x: (dict["x"] as? NSNumber)?.doubleValue ?? 0,
                                             y: (dict["y"] as? NSNumber)?.doubleValue ?? 0)
                        clip.scroll(to: origin)
                        applied[op] = ["x": origin.x, "y": origin.y]
                    } else {
                        unsupported.append(op)
                    }
                case "scroll_to_end", "scroll_to_start":
                    if let scroll = enclosingScrollView(view) {
                        let docH = scroll.contentView.bounds.height
                        let docTotal = scroll.documentView?.bounds.height ?? 0
                        // NSClipView origin is bottom-left: y=0 is the TOP of the
                        // document, y=maxY the bottom.
                        let maxY = max(0, docTotal - docH)
                        let y = op == "scroll_to_end" ? maxY : 0
                        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
                        applied[op] = ["y": y]
                    } else {
                        unsupported.append(op)
                    }
                default:
                    unsupported.append(op)
                }
            }
            var out: [String: Any] = ["target": node.type, "path": node.path]
            if !applied.isEmpty { out["applied"] = applied }
            if !unsupported.isEmpty {
                out["unsupported"] = unsupported
                out["note"] = "supported ops: text, checked, scroll_offset, scroll_to_end, scroll_to_start"
            }
            return out
        },
        description:
            "Targeted writes on a located view (no arbitrary reflection): values maps "
            + "op to argument — text (set a text field's value), checked (set NSButton "
            + "state), scroll_offset {x,y}, scroll_to_end / scroll_to_start (enclosing "
            + "scroll view). Locate with the same key/text/view_type/path/index "
            + "locators as ui_click. Unsupported ops are listed in the result, not "
            + "thrown.",
        payloadSchema:
            #"{"type":"object","properties":{"values":{"type":"object","description":"op → argument map"},"key":{"type":"string"},"text":{"type":"string"},"view_type":{"type":"string"},"path":{"type":"string"},"index":{"type":"integer","minimum":0,"default":0}},"required":["values"],"additionalProperties":false}"#)
}

// MARK: - helpers

private func locateTextInput(_ task: TaskRequest) -> NSView? {
    let tree = NSViewTreeSnapshot()
    guard let node = tree.locate(path: task.str("path"),
                                 key: task.str("key"),
                                 text: nil,
                                 viewType: task.str("view_type"),
                                 index: task.intOf("index", def: 0, min: 0)) else { return nil }
    if node.view is NSTextView || node.view is NSTextField { return node.view }
    var queue: [NSView] = [node.view]
    while !queue.isEmpty {
        let v = queue.removeFirst()
        if v is NSTextView || v is NSTextField { return v }
        queue.append(contentsOf: v.subviews)
    }
    return nil
}

private func applyNSText(_ view: NSView, _ text: String) -> Bool {
    if let field = view as? NSTextField {
        // Focus the field so a following send_key reaches it.
        view.window?.makeFirstResponder(field)
        field.stringValue = text
        if let action = field.action, let target = field.target as? NSObject {
            _ = target.perform(action, with: field)
        }
        NotificationCenter.default.post(
            name: NSControl.textDidChangeNotification, object: field)
        return true
    }
    if let tv = view as? NSTextView {
        tv.string = text
        tv.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification,
                                                 object: tv))
        return true
    }
    return false
}

private func enclosingClipView(_ view: NSView) -> NSClipView? {
    var cur: NSView? = view
    while let v = cur {
        if let clip = v as? NSClipView { return clip }
        cur = v.superview
    }
    return nil
}

private func enclosingScrollView(_ view: NSView) -> NSScrollView? {
    var cur: NSView? = view
    while let v = cur {
        if let scroll = v as? NSScrollView { return scroll }
        cur = v.superview
    }
    return nil
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
#endif
