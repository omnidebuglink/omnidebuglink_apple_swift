import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit

func registerStateTasks() {
    OmniDebugLink.tasks.register(
        "get_state",
        { _ in
            let screens = UIScreen.screens.map { screen -> [String: Any] in
                let b = screen.bounds
                return ["bounds": ["width": b.width, "height": b.height],
                        "scale": screen.scale]
            }
            var windowDescs: [[String: Any]] = []
            for window in UIKitWindows.all() {
                var desc: [String: Any] = [
                    "frame": rectDict(window.frame),
                    "rootViewController": window.rootViewController.map { String(describing: type(of: $0)) } ?? "",
                    "isKeyWindow": window.isKeyWindow,
                ]
                if let root = window.rootViewController {
                    desc["presentedStack"] = presentedChain(root)
                    desc["childViewControllers"] = childChain(root, depth: 3)
                }
                windowDescs.append(desc)
            }
            let trait = UIKitWindows.keyWindow()?.traitCollection
            return [
                "os": OmniDebugLink.platform,
                "osVersion": OmniDebugLink.osVersionString,
                "model": deviceModel,
                "locale": Locale.current.identifier,
                "languageCode": Locale.current.languageCode ?? "",
                "layoutDirection": Locale.characterDirection(forLanguage: Locale.current.identifier) == .rightToLeft
                    ? "rtl" : "ltr",
                "contentSizeCategory": trait?.preferredContentSizeCategory.rawValue ?? "",
                "interfaceStyle": styleName(trait?.userInterfaceStyle),
                "displayScale": UIKitWindows.keyWindow()?.screen.scale ?? UIScreen.main.scale,
                "screens": screens,
                "windows": windowDescs,
                "appState": appStateName(),
                // SwiftUI content only materializes its accessibility tree when
                // an accessibility client is active — surfaced here so the AI
                // knows why SwiftUI pseudo-nodes may be missing.
                "voiceOverRunning": UIAccessibility.isVoiceOverRunning,
            ] as [String: Any]
        },
        description:
            "App/environment snapshot: OS version, device model, locale and layout "
            + "direction, content size category, interface style, screens with bounds "
            + "and scale, each window's root/presented/child view controller stack, "
            + "and application state.")
}

private func styleName(_ style: UIUserInterfaceStyle?) -> String {
    guard let style else { return "unknown" }
    switch style {
    case .dark: return "dark"
    case .light: return "light"
    case .unspecified: return "unspecified"
    @unknown default: return "unknown"
    }
}

private func appStateName() -> String {
    switch UIApplication.shared.applicationState {
    case .active: return "active"
    case .inactive: return "inactive"
    case .background: return "background"
    @unknown default: return "unknown"
    }
}

private func presentedChain(_ root: UIViewController) -> [String] {
    var names = [String(describing: type(of: root))]
    var cur = root.presentedViewController
    while let c = cur, names.count < 10 {
        names.append(String(describing: type(of: c)))
        cur = c.presentedViewController
    }
    return names
}

private func childChain(_ vc: UIViewController, depth: Int) -> [String] {
    guard depth > 0, !vc.children.isEmpty else { return [] }
    return vc.children.prefix(10).map { "\(type(of: $0))" }
}

func rectDict(_ r: CGRect) -> [String: Any] {
    ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
}

/// UIKit window access shared by the tree/action tasks.
enum UIKitWindows {
    static func all() -> [UIWindow] {
        let scenes = UIApplication.shared.connectedScenes
        var windows: [UIWindow] = []
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene {
                windows.append(contentsOf: windowScene.windows)
            }
        }
        if windows.isEmpty { return UIApplication.shared.windows }
        return windows
    }

    /// Foreground/key window: keyWindow of the first active scene, else any window.
    static func keyWindow() -> UIWindow? {
        let windows = all()
        return windows.first { $0.isKeyWindow } ?? windows.first { $0.isHidden == false } ?? windows.first
    }
}

#elseif os(macOS)
import AppKit

func registerStateTasks() {
    OmniDebugLink.tasks.register(
        "get_state",
        { _ in
            let screens = NSScreen.screens.map { screen -> [String: Any] in
                let f = screen.frame
                return ["frame": ["x": f.origin.x, "y": f.origin.y,
                                  "width": f.width, "height": f.height],
                        "scale": screen.backingScaleFactor]
            }
            let windows = NSApp.windows.filter { $0.isVisible }.map { win -> [String: Any] in
                ["title": win.title,
                 "frame": rectDict(win.frame),
                 "isKeyWindow": win.isKeyWindow,
                 "contentViewController": win.contentViewController.map { String(describing: type(of: $0)) } ?? ""]
            }
            return [
                "os": "macos",
                "osVersion": OmniDebugLink.osVersionString,
                "model": deviceModel,
                "locale": Locale.current.identifier,
                "layoutDirection": Locale.characterDirection(forLanguage: Locale.current.identifier) == .rightToLeft
                    ? "rtl" : "ltr",
                "appearance": NSApp.effectiveAppearance.name.rawValue,
                "screens": screens,
                "windows": windows,
            ] as [String: Any]
        },
        description:
            "App/environment snapshot: OS version, device model, locale, appearance, "
            + "screens with frames (AppKit bottom-left origin), and visible windows "
            + "with titles and content view controllers.")
}

func rectDict(_ r: CGRect) -> [String: Any] {
    ["x": r.origin.x, "y": r.origin.y, "width": r.width, "height": r.height]
}

#endif
