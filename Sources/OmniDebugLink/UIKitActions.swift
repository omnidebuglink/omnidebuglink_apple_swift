#if canImport(UIKit)
import UIKit

/// Input injection on iOS/iPadOS/tvOS has NO public synthetic-touch API
/// (UITouch cannot be configured, UIEvent cannot be created). The activation
/// path below is strictly public API and covers the two real-world cases:
///   1. UIControl (and anything inside one) → sendActions — exactly what
///      UIButton.performClick-class automation needs;
///   2. accessibility elements → accessibilityActivate() — this is the public
///      "programmatic tap" and drives SwiftUI Buttons/Links/Toggles that
///      surface as accessible elements.
/// Free-form gesture injection (swipe over non-scroll content, real
/// UILongPressGestureRecognizer firing) is not possible with public API —
/// those tasks degrade gracefully and say so in their return value.

private let coordDoc =
    "Coordinates are floats 0..1, origin at the TOP-LEFT corner of the screen. "
    + "For a pixel (px, py) in a returned screenshot of size W×H (image origin "
    + "top-left): x=(px+0.5)/W, y=(py+0.5)/H (no vertical flip)."

/// First-responder tracking via public API only: sendAction(to: nil) walks the
/// responder chain starting at the first responder, so every UIResponder gains
/// this hook and the one that gets called IS the first responder.
extension UIResponder {
    @objc func odl_captureFirstResponder(_ sender: Any?) {
        UIKitActionsFirstResponderTracker.current = self
    }
}

enum UIKitActionsFirstResponderTracker {
    static weak var current: UIResponder?
    static func find() -> UIResponder? {
        current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.odl_captureFirstResponder(_:)),
                                        to: nil, from: nil, for: nil)
        return current
    }
}

/// Locate the nearest actionable target starting at (and walking up from) the
/// given view. Returns (view, how) or nil.
private func actionableTarget(from view: UIView) -> (UIView, String)? {
    var cur: UIView? = view
    while let v = cur {
        if v is UIControl {
            return (v, "UIControl.sendActions")
        }
        if v.isAccessibilityElement {
            return (v, "accessibilityActivate")
        }
        cur = v.superview
    }
    return nil
}

/// Node-level activation: accessibility pseudo-nodes (SwiftUI elements etc.)
/// activate directly; plain views go through the view-based path. Point/text
/// are forwarded so segment/slider targets can infer the requested state.
private func activateNode(_ node: ViewNode, task: TaskRequest) -> [String: Any] {
    // UIAccessibility is an informal protocol — its members live on NSObject
    // directly, so no protocol cast is possible (or needed).
    if let ax = node.axElement, ax.accessibilityActivate() {
        return ["executed": true,
                "method": "accessibilityActivate(element)",
                "target": node.type] as [String: Any]
    }
    // Element declined or is a plain view — go through the owning view's
    // UIControl path below.
    var point: CGPoint?
    if let f = node.frameInWindow {
        point = CGPoint(x: f.midX, y: f.midY)
    }
    return activate(node.view, at: point, matchText: task.str("text"))
}

private func activate(_ view: UIView,
                      at point: CGPoint? = nil,
                      matchText: String? = nil) -> [String: Any] {
    guard let (target, how) = actionableTarget(from: view) else {
        return ["executed": false,
                "reason": "no UIControl or accessibility element at/above the target; "
                    + "iOS has no public API to fire raw touch handlers or gesture "
                    + "recognizers"] as [String: Any]
    }
    if how == "UIControl.sendActions", let control = target as? UIControl {
        if let sw = control as? UISwitch {
            sw.setOn(!sw.isOn, animated: true)
            control.sendActions(for: .valueChanged)
        } else if let segment = control as? UISegmentedControl {
            return activateSegment(segment, at: point, matchText: matchText)
        } else if let slider = control as? UISlider {
            return activateSlider(slider, at: point)
        } else {
            control.sendActions(for: .touchUpInside)
        }
    } else {
        // accessibilityActivate() returns false when the element has no
        // activate handler — surface that instead of pretending success.
        if !target.accessibilityActivate() {
            // iOS 16+ UISegmentedControl exposes private UISegment subviews as
            // accessible elements WITHOUT an activate handler — route to the
            // segment logic via the enclosing control (point/text still apply).
            var cur: UIView? = target
            while let v = cur {
                if let segment = v as? UISegmentedControl {
                    return activateSegment(segment, at: point, matchText: matchText)
                }
                cur = v.superview
            }
            return ["executed": false,
                    "reason": "accessibilityActivate() returned false (element has no "
                        + "activate handler)",
                    "target": String(describing: type(of: target))] as [String: Any]
        }
    }
    return ["executed": true,
            "method": how,
            "target": String(describing: type(of: target))] as [String: Any]
}

/// Segments aren't subviews, so a blind touchUpInside is a silent no-op — but
/// the caller usually knows WHERE it clicked: infer the segment from the x
/// coordinate (equal-width segments), or match a segment title against the
/// text locator. Only give up when neither is available.
private func activateSegment(_ segment: UISegmentedControl,
                             at point: CGPoint?, matchText: String?) -> [String: Any] {
    var index: Int?
    if let point, segment.window != nil {
        let local = segment.convert(point, from: segment.window)
        if local.x >= 0, local.x <= segment.bounds.width, segment.numberOfSegments > 0 {
            let inferred = Int(local.x / (segment.bounds.width / CGFloat(segment.numberOfSegments)))
            index = min(max(inferred, 0), segment.numberOfSegments - 1)
        }
    }
    if index == nil, let matchText, matchText.count > 0 {
        for i in 0..<segment.numberOfSegments {
            if let title = segment.titleForSegment(at: i),
               title.localizedCaseInsensitiveContains(matchText) {
                index = i
                break
            }
        }
    }
    guard let index else {
        return ["executed": false,
                "reason": "UISegmentedControl selection needs to know WHICH segment: "
                    + "tap it by coordinates (tap_screen) or locate it by segment "
                    + "title text; set_component segment_index also works",
                "target": String(describing: type(of: segment))] as [String: Any]
    }
    segment.selectedSegmentIndex = index
    segment.sendActions(for: .valueChanged)
    return ["executed": true,
            "method": "segment selection (index \(index) via x/title)",
            "segmentIndex": index,
            "segmentTitle": segment.titleForSegment(at: index) ?? "",
            "target": String(describing: type(of: segment))] as [String: Any]
}

/// Same idea for sliders: a real tap at x sets the value to that position.
private func activateSlider(_ slider: UISlider, at point: CGPoint?) -> [String: Any] {
    guard let point, slider.window != nil, slider.bounds.width > 0 else {
        return ["executed": false,
                "reason": "UISlider needs a position to set a value — tap it by "
                    + "coordinates (tap_screen) or use set_component slider_value",
                "target": String(describing: type(of: slider))] as [String: Any]
    }
    let local = slider.convert(point, from: slider.window)
    let fraction = min(max(local.x / slider.bounds.width, 0), 1)
    let value = slider.minimumValue + Float(fraction) * (slider.maximumValue - slider.minimumValue)
    slider.setValue(value, animated: false)
    slider.sendActions(for: .valueChanged)
    return ["executed": true,
            "method": "slider set (via x position)",
            "sliderValue": slider.value,
            "target": String(describing: type(of: slider))] as [String: Any]
}

private func locateForAction(_ task: TaskRequest) throws -> ViewNode {
    let tree = ViewTreeSnapshot()
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

/// Locate a UISegmentedControl by one of its segment titles (titles are not
/// part of the view's text/label, so the generic locator can't reach them).
private func findSegmentNodeByTitle(_ text: String) -> ViewNode? {
    let tree = ViewTreeSnapshot()
    return tree.nodes.first { node in
        guard let segment = node.view as? UISegmentedControl else { return false }
        return (0..<segment.numberOfSegments).contains { i in
            segment.titleForSegment(at: i)?.localizedCaseInsensitiveContains(text) == true
        }
    }
}

// MARK: - tasks

func registerUIKitActionTasks() {
    let t = OmniDebugLink.tasks

    t.register(
        "ui_click",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            let node: ViewNode
            do {
                node = try locateForAction(task)
            } catch let e as TaskException where e.code == "NOT_FOUND" && task.str("text") != nil {
                // Segment titles don't live in node text/label, so the generic
                // locator can't see them — fall back to a segment-title search.
                guard let segNode = findSegmentNodeByTitle(task.str("text")!) else { throw e }
                node = segNode
            }
            let outcome = activateNode(node, task: task)
            var out = outcome
            out["target"] = outcome["target"] ?? node.type
            out["key"] = node.identifier ?? NSNull()
            out["text"] = node.text ?? NSNull()
            out["path"] = node.path
            return out
        },
        description:
            "Click a view through public-API activation: the nearest UIControl at/above "
            + "the target gets sendActions(.touchUpInside) (UISwitch toggles with "
            + ".valueChanged); otherwise the nearest accessibility element gets "
            + "accessibilityActivate() — this is what drives SwiftUI Buttons that carry "
            + "an accessibility identity. Locate by key / text / view_type (substrings, "
            + "case-insensitive) + index, or exact path; finder and activation run "
            + "atomically in one call. Prefer key. Use tap_screen to click by normalized "
            + "screen coordinates instead.",
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
            guard let window = UIKitWindows.keyWindow() else {
                throw TaskException("TASK_FAILED", "no window available")
            }
            let wb = window.bounds
            let point = CGPoint(x: wb.width * CGFloat(x), y: wb.height * CGFloat(y))
            let hit = window.hitTest(point, with: nil)
                ?? window.rootViewController?.view ?? window
            let outcome = activate(hit, at: point)
            var out = outcome
            out["x"] = x
            out["y"] = y
            out["px"] = Int(point.x.rounded())
            out["py"] = Int(point.y.rounded())
            out["screen"] = ["width": Int(wb.width.rounded()), "height": Int(wb.height.rounded())]
            out["hitView"] = String(describing: type(of: hit))
            return out
        },
        description:
            "Activate whatever is at normalized screen coordinates (hit-testing, then "
            + "the same activation path as ui_click). " + coordDoc
            + " Returns the resolved point position, the screen size and the hit view. "
            + "iOS cannot inject raw touch events, so this is activation, not a "
            + "physical tap.",
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
            guard let window = UIKitWindows.keyWindow() else {
                throw TaskException("TASK_FAILED", "no window available")
            }
            let wb = window.bounds
            let start = CGPoint(x: wb.width * CGFloat(x1), y: wb.height * CGFloat(y1))
            let end = CGPoint(x: wb.width * CGFloat(x2), y: wb.height * CGFloat(y2))
            let hit = window.hitTest(start, with: nil)
            var scroll: UIScrollView? = hit as? UIScrollView
            if scroll == nil, let hit {
                var cur: UIView? = hit.superview
                while let v = cur {
                    if let s = v as? UIScrollView { scroll = s; break }
                    cur = v.superview
                }
            }
            guard let scroll else {
                return [
                    "executed": false,
                    "reason": "no UIScrollView at/above the start point; iOS has no "
                        + "public API for free-form gesture injection — scroll views "
                        + "are handled programmatically, other gestures are not",
                    "start": [Int(start.x.rounded()), Int(start.y.rounded())],
                ] as [String: Any]
            }
            let dx = end.x - start.x
            let dy = end.y - start.y
            // A finger moving up (dy<0) scrolls content up = offset increases.
            let target = CGPoint(
                x: min(max(scroll.contentOffset.x - dx, -scroll.contentInset.left),
                       max(0, scroll.contentSize.width - scroll.bounds.width) + scroll.contentInset.right),
                y: min(max(scroll.contentOffset.y - dy, -scroll.contentInset.top),
                       max(0, scroll.contentSize.height - scroll.bounds.height) + scroll.contentInset.bottom))
            scroll.setContentOffset(target, animated: true)
            OmniDebugLink.logBuffer.record(
                "swipe: scrolling \(type(of: scroll)) to (\(Int(target.x)), \(Int(target.y))) over ~\(durationMs)ms",
                level: .log)
            return [
                "executed": true,
                "method": "UIScrollView.setContentOffset",
                "scrollType": String(describing: type(of: scroll)),
                "from": [Int(start.x.rounded()), Int(start.y.rounded())],
                "to": [Int(end.x.rounded()), Int(end.y.rounded())],
                "contentOffset": ["x": target.x, "y": target.y],
            ] as [String: Any]
        },
        description:
            "Swipe from (x1,y1) to (x2,y2), normalized 0..1 coordinates, "
            + "duration_ms 50-3000 (default 300). " + coordDoc
            + " Implemented as a programmatic scroll of the UIScrollView under the "
            + "start point (finger up = content scrolls up); if there is no scroll "
            + "view there it returns executed=false — iOS has no public API for "
            + "free-form gesture injection.",
        payloadSchema:
            #"{"type":"object","properties":{"x1":{"type":"number","minimum":0,"maximum":1},"y1":{"type":"number","minimum":0,"maximum":1},"x2":{"type":"number","minimum":0,"maximum":1},"y2":{"type":"number","minimum":0,"maximum":1},"duration_ms":{"type":"integer","minimum":50,"maximum":3000,"default":300}},"required":["x1","y1","x2","y2"],"additionalProperties":false}"#)

    t.register(
        "long_press",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            let durationMs = task.intOf("duration_ms", def: 800, min: 200, max: 5000)
            var targetView: UIView?
            var pressPoint: CGPoint?
            if let x = task.numOf("x"), let y = task.numOf("y"),
               let window = UIKitWindows.keyWindow() {
                let wb = window.bounds
                let point = CGPoint(x: wb.width * CGFloat(x), y: wb.height * CGFloat(y))
                pressPoint = point
                targetView = window.hitTest(point, with: nil)
            } else if let node = try? locateForAction(task) {
                targetView = node.view
                if let f = node.frameInWindow {
                    pressPoint = CGPoint(x: f.midX, y: f.midY)
                }
            }
            guard let view = targetView else {
                throw TaskException("NOT_FOUND",
                                    "provide x/y coordinates or a locator (key/text/view_type/path)")
            }
            let hasLongPressGR = (view.gestureRecognizers ?? []).contains {
                $0 is UILongPressGestureRecognizer
            } || superviewChain(view).contains {
                ($0.gestureRecognizers ?? []).contains { $0 is UILongPressGestureRecognizer }
            }
            // Public-API limit: a real UILongPressGestureRecognizer cannot be fired
            // programmatically. Controls still get activated; the outcome says what happened.
            let outcome = activate(view, at: pressPoint)
            var out = outcome
            out["durationMs"] = durationMs
            out["approximation"] = true
            out["note"] = "iOS cannot fire UILongPressGestureRecognizer via public API; "
                + "this activated the target like ui_click does. "
                + (hasLongPressGR ? "The target does carry a long-press recognizer — "
                   + "invoke its action directly in a custom task if needed." : "")
            return out
        },
        description:
            "Long-press the target at x/y (normalized 0..1) or at a locator "
            + "(key/text/view_type/path), duration_ms 200-5000 (default 800). "
            + "iOS cannot fire UILongPressGestureRecognizer through public API, so "
            + "this performs the same activation as ui_click and reports the "
            + "approximation in the result.",
        payloadSchema:
            #"{"type":"object","properties":{"x":{"type":"number","minimum":0,"maximum":1},"y":{"type":"number","minimum":0,"maximum":1},"duration_ms":{"type":"integer","minimum":200,"maximum":5000,"default":800},"key":{"type":"string"},"text":{"type":"string"},"view_type":{"type":"string"},"path":{"type":"string"}},"additionalProperties":false}"#)

    t.register(
        "input_text",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            guard let text = task.str("text") else {
                throw TaskException("TASK_INVALID", "text (the value to type) is required")
            }
            // `text` is the VALUE being typed, not a locator — locate the field by
            // key/view_type/path, or fall back to the current first responder.
            var field = locateTextInput(task)
            if field == nil,
               task.str("key") == nil, task.str("view_type") == nil, task.str("path") == nil,
               let responder = UIKitActionsFirstResponderTracker.find(),
               responder is UIView {
                field = responder as? UIView
            }
            guard let view = field else {
                throw TaskException("NOT_FOUND",
                                    "no text field matched the locator and no first "
                                    + "responder is a text input; provide key/view_type/path")
            }
            let applied = applyText(view, text)
            if !applied {
                throw TaskException("TASK_FAILED",
                                    "located view \(type(of: view)) is not a text input")
            }
            return [
                "executed": true,
                "target": String(describing: type(of: view)),
                "text": text,
            ] as [String: Any]
        },
        description:
            "Set text on a text field: locate by key / view_type / path, or omit "
            + "locators to use the currently focused field. The `text` argument is "
            + "the value being typed, not a locator. Setting goes through the "
            + "control's normal change notifications (.editingChanged / "
            + "textViewDidChange), so targets bound to the field update.",
        payloadSchema:
            #"{"type":"object","properties":{"text":{"type":"string","description":"the value to type"},"key":{"type":"string"},"view_type":{"type":"string"},"path":{"type":"string"}},"required":["text"],"additionalProperties":false}"#)

    t.register(
        "send_key",
        { task in
            try OmniDebugLink.ensureActionsEnabled()
            guard let key = task.str("key") else {
                throw TaskException("TASK_INVALID", "key is required")
            }
            guard let responder = UIKitActionsFirstResponderTracker.find() else {
                throw TaskException("TASK_FAILED", "no first responder to send a key to")
            }
            switch key {
            case "enter", "return":
                guard let input = responder as? UIKeyInput else {
                    throw TaskException("TASK_FAILED",
                                        "first responder \(type(of: responder)) does not accept text input")
                }
                input.insertText("\n")
            case "tab":
                guard let input = responder as? UIKeyInput else {
                    throw TaskException("TASK_FAILED",
                                        "first responder \(type(of: responder)) does not accept text input")
                }
                input.insertText("\t")
            case "space":
                guard let input = responder as? UIKeyInput else {
                    throw TaskException("TASK_FAILED",
                                        "first responder \(type(of: responder)) does not accept text input")
                }
                input.insertText(" ")
            case "del", "backspace":
                guard let input = responder as? UIKeyInput else {
                    throw TaskException("TASK_FAILED",
                                        "first responder \(type(of: responder)) does not accept text input")
                }
                input.deleteBackward()
            case "escape", "cancel":
                responder.resignFirstResponder()
            default:
                throw TaskException("TASK_INVALID",
                                    "key must be one of enter|return|tab|space|del|escape|cancel")
            }
            return ["executed": true,
                    "key": key,
                    "responder": String(describing: type(of: responder))] as [String: Any]
        },
        description:
            "Send a soft key to the focused responder via UIKeyInput: "
            + "enter/return, tab, space, del (backspace), escape/cancel (resigns "
            + "first responder). Hardware/system keys cannot be injected on iOS.",
        payloadSchema:
            #"{"type":"object","properties":{"key":{"type":"string","enum":["enter","return","tab","space","del","backspace","escape","cancel"]}},"required":["key"],"additionalProperties":false}"#)

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
                    if let s = arg as? String, applyText(view, s) {
                        applied[op] = true
                    } else {
                        unsupported.append(op)
                    }
                case "checked":
                    if let sw = view as? UISwitch {
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
                        sw.setOn(on, animated: true)
                        sw.sendActions(for: .valueChanged)
                        applied[op] = sw.isOn
                    } else {
                        unsupported.append(op)
                    }
                case "scroll_offset":
                    if let scroll = view as? UIScrollView, let dict = arg as? [String: Any] {
                        let offset = CGPoint(x: (dict["x"] as? NSNumber)?.doubleValue ?? 0,
                                             y: (dict["y"] as? NSNumber)?.doubleValue ?? 0)
                        scroll.setContentOffset(offset, animated: false)
                        applied[op] = ["x": offset.x, "y": offset.y]
                    } else {
                        unsupported.append(op)
                    }
                case "scroll_to_end", "scroll_to_start":
                    if let scroll = view as? UIScrollView {
                        let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
                        let y = op == "scroll_to_end" ? maxY : 0
                        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
                        applied[op] = ["x": scroll.contentOffset.x, "y": y]
                    } else {
                        unsupported.append(op)
                    }
                case "segment_index":
                    if let seg = view as? UISegmentedControl, let n = arg as? NSNumber,
                       n.intValue >= 0, n.intValue < seg.numberOfSegments {
                        seg.selectedSegmentIndex = n.intValue
                        seg.sendActions(for: .valueChanged)
                        applied[op] = seg.selectedSegmentIndex
                    } else {
                        unsupported.append(op)
                    }
                case "slider_value":
                    if let slider = view as? UISlider, let n = arg as? NSNumber {
                        slider.value = n.floatValue // auto-clamped to min...max
                        slider.sendActions(for: .valueChanged)
                        applied[op] = slider.value
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
                out["note"] = "supported ops: text, checked, segment_index, slider_value, "
                    + "scroll_offset, scroll_to_end, scroll_to_start"
            }
            return out
        },
        description:
            "Targeted writes on a located view (no arbitrary reflection): values maps "
            + "op to argument — text (set a text field's value), checked (toggle "
            + "UISwitch), segment_index (select a UISegmentedControl segment), "
            + "slider_value (set UISlider, auto-clamped), scroll_offset {x,y}, "
            + "scroll_to_end / scroll_to_start (UIScrollView). Locate with the same "
            + "key/text/view_type/path/index locators as ui_click. Unsupported ops "
            + "are listed in the result, not thrown.",
        payloadSchema:
            #"{"type":"object","properties":{"values":{"type":"object","description":"op → argument map"},"key":{"type":"string"},"text":{"type":"string"},"view_type":{"type":"string"},"path":{"type":"string"},"index":{"type":"integer","minimum":0,"default":0}},"required":["values"],"additionalProperties":false}"#)
}

// MARK: - helpers

private func superviewChain(_ view: UIView) -> [UIView] {
    var out: [UIView] = []
    var cur = view.superview
    while let v = cur {
        out.append(v)
        cur = v.superview
    }
    return out
}

/// Resolve the locator to an actual text input (or a view containing one).
private func locateTextInput(_ task: TaskRequest) -> UIView? {
    let tree = ViewTreeSnapshot()
    guard let node = tree.locate(path: task.str("path"),
                                 key: task.str("key"),
                                 text: nil,
                                 viewType: task.str("view_type"),
                                 index: task.intOf("index", def: 0, min: 0)) else { return nil }
    if isTextInput(node.view) { return node.view }
    // The locator may point at a wrapper (stack view, cell, hosting view):
    // take its first text-input descendant.
    var queue: [UIView] = [node.view]
    while !queue.isEmpty {
        let v = queue.removeFirst()
        if isTextInput(v) { return v }
        queue.append(contentsOf: v.subviews)
    }
    return nil
}

private func isTextInput(_ view: UIView) -> Bool {
    view is UITextField || view is UITextView
}

/// Set text and fire the normal change notifications. The field also becomes
/// first responder so a following send_key has somewhere to go (real-device
/// lesson: setting .text alone leaves the responder chain untouched).
private func applyText(_ view: UIView, _ text: String) -> Bool {
    if let field = view as? UITextField {
        field.becomeFirstResponder()
        field.text = text
        field.sendActions(for: .editingChanged)
        if let delegate = field.delegate,
           delegate.responds(to: #selector(UITextFieldDelegate.textFieldDidChangeSelection(_:))) {
            delegate.textFieldDidChangeSelection?(field)
        }
        return true
    }
    if let tv = view as? UITextView {
        tv.becomeFirstResponder()
        tv.text = text
        tv.delegate?.textViewDidChange?(tv)
        return true
    }
    return false
}
#endif
