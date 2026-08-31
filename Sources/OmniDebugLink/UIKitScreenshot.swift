#if canImport(UIKit)
import UIKit

/// Screenshot budget: the relay caps a single message at ~900KB and base64
/// inflates by 4/3, so budget by BASE64 STRING LENGTH (850k), not bytes.
/// Oversized captures first drop JPEG quality, then downscale 0.75x up to 3
/// times (min longest edge 200).
private let maxBase64Length = 850_000
private let minLongestEdge = 200

func registerUIKitScreenshotTasks() {
    OmniDebugLink.tasks.register(
        "screenshot",
        { task in
            let maxSize = task.intOf("max_size", def: 1280, min: 64, max: 4096)
            guard let window = UIKitWindows.keyWindow() else {
                throw TaskException("NO_FRAME", "no window to capture")
            }
            let bounds = window.bounds
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
            let image = renderer.image { _ in
                window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            return try encodeJpegEnvelope(image: image, maxSize: maxSize)
        },
        description:
            "Capture the foreground window as JPEG via drawHierarchy. max_size "
            + "(64-4096, default 1280) caps the longest edge in pixels. Returned in "
            + "the __odl_file envelope (image/jpeg, base64); oversized captures are "
            + "re-compressed/downscaled automatically to stay under the relay's "
            + "single-message limit. Pixel origin is TOP-LEFT, matching the "
            + "normalized coordinate space of tap_screen/swipe.",
        payloadSchema:
            #"{"type":"object","properties":{"max_size":{"type":"integer","minimum":64,"maximum":4096,"default":1280,"description":"cap for the longest edge in pixels"}},"additionalProperties":false}"#)
}

func encodeJpegEnvelope(image: UIImage, maxSize: Int) throws -> [String: Any] {
    let originalW = Int(image.size.width * image.scale)
    let originalH = Int(image.size.height * image.scale)
    var current = image
    var longest = max(originalW, originalH)
    if longest > maxSize {
        current = downscale(current, to: maxSize)
        longest = max(Int(current.size.width * current.scale), Int(current.size.height * current.scale))
    }
    for _ in 0..<4 {
        var quality: CGFloat = 0.7
        while quality >= 0.2 {
            if let data = current.jpegData(compressionQuality: quality) {
                let b64 = data.base64EncodedString()
                if b64.count <= maxBase64Length {
                    return [
                        "format": "jpeg",
                        "width": Int(current.size.width * current.scale),
                        "height": Int(current.size.height * current.scale),
                        "originalWidth": originalW,
                        "originalHeight": originalH,
                        "bytes": data.count,
                        "__odl_file": ["mime": "image/jpeg", "data": b64],
                    ] as [String: Any]
                }
            }
            quality -= 0.15
        }
        if longest <= minLongestEdge {
            break
        }
        current = downscale(current, to: Int(Double(longest) * 0.75))
        longest = max(Int(current.size.width * current.scale), Int(current.size.height * current.scale))
    }
    throw TaskException("SCREENSHOT_TOO_LARGE",
                        "could not fit screenshot under the base64 budget even after downscaling")
}

private func downscale(_ image: UIImage, to longestEdge: Int) -> UIImage {
    let w = image.size.width * image.scale
    let h = image.size.height * image.scale
    let longest = max(w, h)
    guard longest > CGFloat(longestEdge) else { return image }
    let factor = CGFloat(longestEdge) / longest
    let newSize = CGSize(width: w * factor, height: h * factor)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
    return renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: newSize))
    }
}
#endif
