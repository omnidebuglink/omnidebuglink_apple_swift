#if os(macOS)
import AppKit

private let maxBase64Length = 850_000

func registerAppKitScreenshotTasks() {
    OmniDebugLink.tasks.register(
        "screenshot",
        { task in
            let maxSize = task.intOf("max_size", def: 1280, min: 64, max: 4096)
            guard let window = AppKitWindows.target(),
                  let content = window.contentView else {
                throw TaskException("NO_FRAME", "no window to capture")
            }
            let bounds = content.bounds
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: Int(bounds.width),
                                       pixelsHigh: Int(bounds.height),
                                       bitsPerSample: 8,
                                       samplesPerPixel: 4,
                                       hasAlpha: true,
                                       isPlanar: false,
                                       colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0,
                                       bitsPerPixel: 0)
            guard let rep else {
                throw TaskException("TASK_FAILED", "could not allocate bitmap for capture")
            }
            // cacheDisplay is layer-safe for ordinary view content (no GL/Metal
            // surfaces — those need ScreenCaptureKit and screen permission).
            content.cacheDisplay(in: bounds, to: rep)
            let originalW = rep.pixelsWide
            let originalH = rep.pixelsHigh
            var longest = max(originalW, originalH)
            var current = rep
            if longest > maxSize {
                let factor = Double(maxSize) / Double(longest)
                let newSize = CGSize(width: Int(Double(originalW) * factor),
                                     height: Int(Double(originalH) * factor))
                let scaled = NSBitmapImageRep(bitmapDataPlanes: nil,
                                              pixelsWide: Int(newSize.width),
                                              pixelsHigh: Int(newSize.height),
                                              bitsPerSample: 8,
                                              samplesPerPixel: 4,
                                              hasAlpha: true,
                                              isPlanar: false,
                                              colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0,
                                              bitsPerPixel: 0)
                if let scaled {
                    let ctx = NSGraphicsContext(bitmapImageRep: scaled)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    current.draw(in: CGRect(origin: .zero, size: newSize))
                    NSGraphicsContext.restoreGraphicsState()
                    current = scaled
                    longest = max(current.pixelsWide, current.pixelsHigh)
                }
            }
            var quality: Double = 0.7
            while quality >= 0.2 {
                if let data = current.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: quality]),
                   data.base64EncodedString().count <= maxBase64Length {
                    let b64 = data.base64EncodedString()
                    return [
                        "format": "jpeg",
                        "width": current.pixelsWide,
                        "height": current.pixelsHigh,
                        "originalWidth": originalW,
                        "originalHeight": originalH,
                        "bytes": data.count,
                        "__odl_file": ["mime": "image/jpeg", "data": b64],
                    ] as [String: Any]
                }
                quality -= 0.15
            }
            throw TaskException("SCREENSHOT_TOO_LARGE",
                                "could not fit screenshot under the base64 budget")
        },
        description:
            "Capture the key window's content view as JPEG via cacheDisplay. max_size "
            + "(64-4096, default 1280) caps the longest edge in pixels. Returned in "
            + "the __odl_file envelope (image/jpeg, base64), compressed automatically "
            + "to stay under the relay's single-message limit. Pixel origin is "
            + "TOP-LEFT, matching the normalized coordinate space of tap_screen/swipe. "
            + "GPU-rendered surfaces (Metal/OpenGL layers) are not captured by "
            + "cacheDisplay.",
        payloadSchema:
            #"{"type":"object","properties":{"max_size":{"type":"integer","minimum":64,"maximum":4096,"default":1280,"description":"cap for the longest edge in pixels"}},"additionalProperties":false}"#)
}
#endif
