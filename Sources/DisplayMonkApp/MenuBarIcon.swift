import AppKit
import DisplayMonkCore

/// The menu bar icon: the monitor with closed eyes from Resources/MenuBarIcon.svg. It is drawn
/// as a template image (dark shapes filled, light shapes cut out), so macOS tints it for light
/// and dark menu bars, and rendered at 1x and 2x so it stays crisp.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            if let representation = render(pixels: Int(size.width) * scale, size: size) {
                image.addRepresentation(representation)
            }
        }
        image.isTemplate = true
        image.accessibilityDescription = "Display Monk"
        return image
    }()

    private struct Shape {
        let path: NSBezierPath
        let cutOut: Bool
    }

    /// The SVG's shapes in drawing order, in its 48x48 viewBox.
    private static var shapes: [Shape] {
        [
            Shape(path: path("M17.9482 41.5355C17.2099 41.4061 17.3045 40.3184 18.054 40.3184H29.0966C29.8578 40.3184 29.9443 41.4271 29.1924 41.5453C28.1707 41.7058 28.1413 43.1664 29.1558 43.3679L32.1298 43.9585C32.7087 44.0735 32.6249 44.9258 32.0347 44.9258H15.3947C14.8075 44.9258 14.713 44.0829 15.2857 43.9529L17.9931 43.3383C18.9726 43.116 18.9375 41.7088 17.9482 41.5355Z"), cutOut: false),
            Shape(path: roundedRect(x: 6, y: 13.0742, width: 36, height: 28, radius: 6), cutOut: false),
            Shape(path: roundedRect(x: 9, y: 16.0742, width: 30, height: 22, radius: 4), cutOut: true),
            Shape(path: path("M11 26.0742C11 22.303 11 20.4174 12.1716 19.2458C13.3431 18.0742 15.2288 18.0742 19 18.0742H29C32.7712 18.0742 34.6569 18.0742 35.8284 19.2458C37 20.4174 37 22.303 37 26.0742V28.0742C37 31.8455 37 33.7311 35.8284 34.9026C34.6569 36.0742 32.7712 36.0742 29 36.0742H19C15.2288 36.0742 13.3431 36.0742 12.1716 34.9026C11 33.7311 11 31.8455 11 28.0742V26.0742Z"), cutOut: false),
            Shape(path: path("M15.045 29.2222C14.7159 29.1792 14.4792 28.8749 14.5778 28.5581C14.769 27.9437 15.1272 27.3898 15.6176 26.9614C16.2599 26.4003 17.0848 26.0929 17.9376 26.0967C18.7904 26.1006 19.6125 26.4155 20.2497 26.9823C20.7362 27.4152 21.0893 27.9722 21.275 28.5883C21.3708 28.906 21.1313 29.2081 20.8019 29.2482C20.4725 29.2883 20.18 29.0485 20.0562 28.7406C19.9246 28.4133 19.7185 28.1181 19.4509 27.8801C19.0324 27.5077 18.4924 27.3009 17.9322 27.2984C17.372 27.2958 16.8301 27.4978 16.4082 27.8664C16.1385 28.102 15.9297 28.3953 15.7952 28.7214C15.6686 29.0281 15.374 29.2653 15.045 29.2222Z"), cutOut: true),
            Shape(path: path("M27.7598 29.2222C27.4308 29.1792 27.194 28.8749 27.2926 28.5581C27.4839 27.9437 27.8421 27.3898 28.3325 26.9614C28.9747 26.4003 29.7996 26.0929 30.6524 26.0967C31.5053 26.1006 32.3274 26.4155 32.9645 26.9823C33.451 27.4152 33.8042 27.9722 33.9899 28.5883C34.0856 28.906 33.8461 29.2081 33.5167 29.2482C33.1873 29.2883 32.8949 29.0485 32.7711 28.7406C32.6395 28.4133 32.4333 28.1181 32.1658 27.8801C31.7472 27.5077 31.2072 27.3009 30.647 27.2984C30.0868 27.2958 29.5449 27.4978 29.1231 27.8664C28.8534 28.102 28.6446 28.3953 28.51 28.7214C28.3834 29.0281 28.0888 29.2653 27.7598 29.2222Z"), cutOut: true),
            // The three rays above the monitor.
            Shape(path: roundedRect(x: 14.4492, y: 5.91846, width: 3, height: 6, radius: 1.5, transform: rotation(degrees: -30, cx: 14.4492, cy: 5.91846)), cutOut: false),
            Shape(path: roundedRect(x: 0, y: 0, width: 3, height: 6, radius: 1.5, transform: matrix(-0.866025, -0.5, -0.5, 0.866025, 33.2773, 5.96729)), cutOut: false),
            Shape(path: roundedRect(x: 0, y: 0, width: 3, height: 8, radius: 1.5, transform: matrix(1, 0, 0, -1, 22.8633, 9.83447)), cutOut: false),
        ]
    }

    private static func render(pixels: Int, size: NSSize) -> NSBitmapImageRep? {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // SVG's y axis points down; scale the 48-unit viewBox to the bitmap.
        let scale = CGFloat(pixels) / 48
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: CGFloat(pixels))
        transform.scaleX(by: scale, yBy: -scale)
        transform.concat()
        NSColor.black.setFill()
        for shape in shapes {
            context.compositingOperation = shape.cutOut ? .destinationOut : .sourceOver
            shape.path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        representation.size = size
        return representation
    }

    private static func path(_ data: String) -> NSBezierPath {
        let path = NSBezierPath()
        for command in SVGPath.parse(data) ?? [] {
            switch command {
            case let .move(x, y): path.move(to: NSPoint(x: x, y: y))
            case let .line(x, y): path.line(to: NSPoint(x: x, y: y))
            case let .curve(x1, y1, x2, y2, x, y):
                path.curve(to: NSPoint(x: x, y: y), controlPoint1: NSPoint(x: x1, y: y1), controlPoint2: NSPoint(x: x2, y: y2))
            case .close: path.close()
            }
        }
        return path
    }

    private static func roundedRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat, transform: AffineTransform? = nil) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: radius, yRadius: radius)
        if let transform { path.transform(using: transform) }
        return path
    }

    /// SVG `matrix(a b c d e f)`.
    private static func matrix(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ e: CGFloat, _ f: CGFloat) -> AffineTransform {
        AffineTransform(m11: a, m12: b, m21: c, m22: d, tX: e, tY: f)
    }

    /// SVG `rotate(degrees cx cy)`.
    private static func rotation(degrees: CGFloat, cx: CGFloat, cy: CGFloat) -> AffineTransform {
        let radians = degrees * .pi / 180
        let cosine = cos(radians), sine = sin(radians)
        return matrix(cosine, sine, -sine, cosine, cx - cosine * cx + sine * cy, cy - sine * cx - cosine * cy)
    }
}
