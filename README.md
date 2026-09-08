# OmniDebugLink Apple SDK

OmniDebugLink remote-debugging client SDK (Swift Package, `OmniDebugLink`)
for iOS / iPadOS / tvOS / Mac Catalyst (UIKit line) and macOS (AppKit line).
Protocol semantics align with the Flutter/Android clients: coordinates are
normalized 0-1 with a **top-left origin**, screenshots use the `__odl_file`
envelope (JPEG), and the hello capability list is announced per platform.

## Install

SPM (GitHub git dependency, ref by tag):

```swift
.package(url: "https://github.com/omnidebuglink/omnidebuglink_apple_swift.git", from: "0.2.2")
```

## Usage

```swift
import OmniDebugLink

// In AppDelegate.application(_:didFinishLaunching:) / App.init():
OmniDebugLink.start("<clientToken>")
```

- `OmniDebugLink.actionsEnabled` (default true): master switch for write
  operations — false = read-only observation mode, announced with hello;
  changes re-send hello automatically (or call `announce()` manually)
- `OmniDebugLink.recordLog(_:level:)` / `recordError(_:)`: forward logs into
  the `read_logs` buffer (Apple platforms have no historical-log API — only
  forwarded content is captured)
- Custom tasks: `OmniDebugLink.tasks.register("my_task", { req in ["ok": true] }, description: "...")`

**One token pair = one device seat.** When replaced by a newer connection
with the same token the SDK receives close code 4000, stops reconnecting
permanently and **exits the app** — a live token in a release build must
not stay silent. Never share a token pair across devices.

> ### ⚠️ Never call `start()` unconditionally — and never embed a token in a release build
>
> `start()` opens a debug channel that can inspect and drive your app.
> **Debug builds**: start freely — gate the call on the `#if DEBUG`
> compilation condition.
> **Release builds**: only behind a runtime condition — a token issued by your
> own backend to an authorized account, never one baked into the binary
> ([production pattern](https://github.com/omnidebuglink/omnidebuglink/blob/main/sdk-integration.md#production--conditional-debugging)).
>
> Every connection with the same token kicks the previous one offline, and
> being kicked terminates the app by design (see above). If `start()` ships
> in a release build, your users' sessions will be terminated and any loss
> that results is on you, not on OmniDebugLink.

## Built-in tasks

Available on all platforms (including watchOS):

| Task | What it does |
|---|---|
| `echo` / `ping` / `get_stats` | Connectivity basics and runtime stats |
| `read_logs` | 1000-entry ring buffer of forwarded logs and uncaught exceptions (no history before start) |
| `prefs` | NSUserDefaults / UserDefaults: get / set / delete / list with valueType coercion |
| `get_perf` | fps + frame-time percentiles, memory, device snapshot |
| `get_state` | App/version state, screen metrics, keyboard/VoiceOver status (reduced set on watchOS) |

UIKit line (iOS/iPadOS/tvOS/Catalyst) and AppKit line (macOS) share this set:

| Task | What it does |
|---|---|
| `ui_traverse` | View tree snapshot, flat list by default (3000-node cap); SwiftUI controls are flattened in from the host view's accessibilityElements as addressable pseudo-nodes |
| `find_objects` | Search by `key` (accessibilityIdentifier, recommended) / `text` / `view_type` substring + `index`; SwiftUI targets locate best by accessibility **label** + text |
| `view_component` | One node in depth: Mirror-reflected properties with KVC guards (bool vs number disambiguated, crashing getters skipped) |
| `wait_for` | Poll every 200 ms until a key/text/view_type match appears; timeout returns `found: false`, not an error |
| `screenshot` | JPEG via `drawHierarchy` (UIKit) / `cacheDisplay` (AppKit, GPU layers not captured), `__odl_file` envelope with quality-then-downsample budget |
| `ui_click` | Public-API activation: nearest UIControl gets `sendActions(.touchUpInside)` (switches fire `.valueChanged`), otherwise `accessibilityActivate()` — the public programmatic tap that drives SwiftUI Buttons. Segments/sliders infer the intended segment/value from the click x coordinate |
| `tap_screen` | iOS: no public touch synthesis, so this activates the element at the point via the same channels; macOS: synthesized `NSEvent` click queued through `NSApp.postEvent` — a real event routed like user input |
| `swipe` | iOS: programmatic `UIScrollView` scrolling (direction matches finger semantics); macOS: real NSEvent drag |
| `long_press` | Activation-style hold (iOS); real NSEvent press-hold-release (macOS) |
| `input_text` | Write into the first responder's field (captured via the responder-chain `sendAction(to: nil)` trick, no private API) |
| `send_key` | iOS: UIKeyInput soft dispatch (enter/tab/space/del/escape); macOS: real NSEvent key codes |
| `set_component` | Mutate text / segment_index / slider_value / switch state and similar targeted properties |

macOS input injection synthesizes `NSEvent`s in-process and queues them via
`NSApp.postEvent` (no accessibility permission needed;
`CGEvent.postToPid` was measured as ignored by AppKit on macOS 12 Intel).
iOS has **no public touch synthesis** — UITouch cannot be configured — so
the UIKit line uses the activation channels above; free-form gesture
injection is not possible there with public API.

The addressing model matches the other clients: `key` / `text` /
`view_type` substring + `index` disambiguation, with `path` as an exact
fallback; find and act happen atomically within one task. SwiftUI controls
live in the host view's accessibilityElements rather than the view subtree
— set `.accessibilityLabel()` on SwiftUI controls to locate them by text
and activate them via ui_click.

## Platform maturity

| Line | Status |
|---|---|
| iOS / iPadOS (UIKit) | **Verified**: full end-to-end run on Xcode 14 + iOS 16.2 simulator (connection/heartbeat/4000 replacement stop, all tasks, SwiftUI activation, screenshot budget) |
| macOS (AppKit) | **Verified**: on Xcode 14 + macOS 12.5 Intel hardware (connection/heartbeat, coordinate/screenshot consistency, NSEvent injection across all tasks, real SwiftUI control clicks, KVC reflection SEL guards). Note: the original CGEvent path was measured as **completely unreachable** on this machine (`postToPid` events never enter the app event loop; `CGWarp` equally dead; synthesized `scrollWheel` has no factory carrying a windowNumber). Final design: `NSEvent` construction + `NSApp.postEvent`, aligned with the iOS programmatic-scroll approach |
| tvOS / Mac Catalyst | Runs the UIKit-line code; not separately verified |

## Known limitations (iOS line)

iOS has no public touch-injection API: `ui_click`/`tap_screen` go through
UIControl `sendActions` + `accessibilityActivate()` (both can drive SwiftUI
Buttons); `swipe` only performs programmatic scrolling on UIScrollView;
`long_press` approximates activation (UILongPressGestureRecognizer cannot
be triggered publicly). Each task's return value states honestly what was
actually done.

## License

Released under the [MIT License](LICENSE).
