# OmniDebugLink Apple SDK

OmniDebugLink remote-debugging client SDK (Swift Package, `OmniDebugLink`)
for iOS / iPadOS / tvOS / Mac Catalyst (UIKit line) and macOS (AppKit line).
Protocol semantics align with the Flutter/Android clients: coordinates are
normalized 0-1 with a **top-left origin**, screenshots use the `__odl_file`
envelope (JPEG), and the hello capability list is announced per platform.

## Install

SPM (GitHub git dependency, ref by tag):

```swift
.package(url: "https://github.com/omnidebuglink/omnidebuglink_apple.git", from: "0.1.0")
```

## Usage

```swift
import OmniDebugLink

// In AppDelegate.application(_:didFinishLaunching:) / App.init():
OmniDebugLink.start("wss://api.omnidebuglink.dev/ws?token=<clientToken>")
```

- `OmniDebugLink.actionsEnabled` (default true): master switch for write
  operations — false = read-only observation mode, announced with hello;
  changes re-send hello automatically (or call `announce()` manually)
- `OmniDebugLink.recordLog(_:level:)` / `recordError(_:)`: forward logs into
  the `read_logs` buffer (Apple platforms have no historical-log API — only
  forwarded content is captured)
- Custom tasks: `OmniDebugLink.tasks.register("my_task", { req in ["ok": true] }, description: "...")`

**One token pair = one device seat.** When replaced by a newer connection
with the same token the SDK receives close code 4000 and stops reconnecting
permanently (a warning is logged); never share a token pair across devices.

## Built-in tasks

- All platforms: `echo` / `ping` / `get_stats` / `read_logs` / `prefs` /
  `get_perf` / `get_state`
- iOS/iPadOS/tvOS/Catalyst: `ui_traverse` / `find_objects` /
  `view_component` / `wait_for` / `screenshot` (read); `ui_click` /
  `tap_screen` / `swipe` / `long_press` / `input_text` / `send_key` /
  `set_component` (write)
- macOS: same set; input injection goes through `NSEvent` (synthesized
  in-process and queued via `NSApp.postEvent`, no accessibility permission
  needed; `CGEvent.postToPid` was measured as ignored by AppKit on
  macOS 12 Intel)

The addressing model matches the other clients: `key`
(accessibilityIdentifier, recommended) / `text` / `view_type` substring +
`index` disambiguation, with `path` as an exact fallback; find and act
happen atomically within one task. SwiftUI controls live in the host
view's accessibilityElements rather than the view subtree — the SDK
flattens them into addressable nodes; set `.accessibilityIdentifier()` on
SwiftUI controls to locate them by key and activate them via ui_click.

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
