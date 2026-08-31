# OmniDebugLink Apple SDK

OmniDebugLink 远程调试客户端 SDK（Swift Package，`OmniDebugLink`），支持 iOS /
iPadOS / tvOS / Mac Catalyst（UIKit 线）和 macOS（AppKit 线）。协议语义与
Flutter/Android 客户端对齐：坐标 0-1 归一化**原点左上**、截图走 `__odl_file`
信封（JPEG）、hello 能力清单随平台自动上报。

## 安装

SPM（GitHub git 依赖，`omnidebuglink/omnidebuglink_apple`，ref 用 tag）：

```swift
.package(url: "https://github.com/omnidebuglink/omnidebuglink_apple.git", from: "0.1.0")
```

## 接入

```swift
import OmniDebugLink

// AppDelegate.application(_:didFinishLaunching:) / App.init() 里：
OmniDebugLink.start("wss://api.omnidebuglink.dev/ws?token=<clientToken>")
```

- `OmniDebugLink.actionsEnabled`（默认 true）：写操作总开关，false = 只读观察模式，
  随 hello 上报；改动会自动重发 hello（也可手动 `announce()`）
- `OmniDebugLink.recordLog(_:level:)` / `recordError(_:)`：转发日志进 `read_logs`
  缓冲（Apple 平台无历史日志 API，只采集转发进来的内容）
- 自定义 task：`OmniDebugLink.tasks.register("my_task", { req in ["ok": true] }, description: "...")`

**一个 token 对 = 一台设备的席位**。SDK 被同 token 的新连接顶替时会收到关闭码
4000 并永久停止重连（日志中有警告）；不要在两台设备上用同一对 token。

## 内置 task

- 全平台：`echo` / `ping` / `get_stats` / `read_logs` / `prefs` / `get_perf` / `get_state`
- iOS/iPadOS/tvOS/Catalyst：`ui_traverse` / `find_objects` / `view_component` /
  `wait_for` / `screenshot`（读）；`ui_click` / `tap_screen` / `swipe` /
  `long_press` / `input_text` / `send_key` / `set_component`（写）
- macOS：同上，输入注入走 `NSEvent`（进程内合成后通过 `NSApp.postEvent` 进队列，
  无需辅助功能权限；`CGEvent.postToPid` 在 macOS 12 Intel 实测被 AppKit 忽略）

寻址模型与其他端一致：`key`（accessibilityIdentifier，推荐）/ `text` / `view_type`
子串匹配 + `index` 消歧，`path` 精确兜底；find 与 act 在一次 task 内原子完成。
SwiftUI 控件不在视图子树里、而在宿主 view 的 accessibilityElements 里——SDK 会把它们
拍平成可寻址节点；给 SwiftUI 控件设 `.accessibilityIdentifier()` 即可被 key 定位、被
ui_click 激活。

## 平台成熟度

| 线 | 状态 |
|---|---|
| iOS / iPadOS（UIKit 线） | **已验证**：Xcode 14 + iOS 16.2 模拟器全链路实测（连接/心跳/4000 顶替停机、全套 task、SwiftUI 激活、截图预算） |
| macOS（AppKit 线） | **已验证**：Xcode 14 + macOS 12.5 Intel 真机实测（连接/心跳、坐标系统/截图一致性、NSEvent 注入全套 task、SwiftUI 控件真实可点击、KVC 属性反射 SEL 类型防护）。注：原 CGEvent 注入路径在本机实测**完全不可达**（`postToPid` 事件不进入 app 事件循环，`CGWarp` 也无效；合成 `scrollWheel` 无带 windowNumber 的工厂、CGEvent 包出的事件被丢弃）。最终走 `NSEvent` 构造 + `NSApp.postEvent` 进队列，与 iOS 的程序化滚动方案对齐 |
| tvOS / Mac Catalyst | 走 UIKit 线代码，未单独验证 |

tvOS / Mac Catalyst 走 UIKit 线代码，未单独验证。

## 已知限制（iOS 线）

iOS 无公开触摸注入 API：`ui_click`/`tap_screen` 走 UIControl `sendActions` +
`accessibilityActivate()`（可驱动 SwiftUI Button）；`swipe` 仅对 UIScrollView
做程序滚动；`long_press` 近似为激活（UILongPressGestureRecognizer 无法公开触发）。
各 task 的返回值会如实说明实际执行方式。
