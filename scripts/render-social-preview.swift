import AppKit

// Run from the repository root: swift scripts/render-social-preview.swift
let width = 1280
let height = 640
let output = URL(fileURLWithPath: "docs/social-preview.png")

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width,
    pixelsHigh: height,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create social preview bitmap")
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func roundRect(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func label(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, fill: NSColor, tracking: CGFloat = 0) {
    let text = NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: fill,
        .kern: tracking
    ])
    text.draw(at: NSPoint(x: x, y: y))
}

func check(x: CGFloat, y: CGFloat, fill: NSColor) {
    let path = NSBezierPath()
    path.lineWidth = 11
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: NSPoint(x: x - 23, y: y))
    path.line(to: NSPoint(x: x - 5, y: y - 18))
    path.line(to: NSPoint(x: x + 27, y: y + 22))
    fill.setStroke()
    path.stroke()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let bounds = NSRect(x: 0, y: 0, width: width, height: height)
NSGradient(starting: color(0x142944), ending: color(0x09121f))!
    .draw(in: bounds, angle: -18)

// Small brand mark, drawn here so the share image has no embedded raster assets.
roundRect(NSRect(x: 72, y: 500, width: 70, height: 70), radius: 20, fill: color(0x1f4160), stroke: color(0x426889))
let mark = NSBezierPath()
mark.lineWidth = 7
mark.lineCapStyle = .round
mark.move(to: NSPoint(x: 95, y: 520))
mark.line(to: NSPoint(x: 95, y: 549))
mark.move(to: NSPoint(x: 119, y: 550))
mark.line(to: NSPoint(x: 119, y: 521))
color(0x7eb4ff).setStroke()
mark.stroke()
label("ScrollFix", x: 158, y: 515, size: 31, weight: .bold, fill: color(0xeef4fb))

label("Natural trackpad.", x: 72, y: 393, size: 54, weight: .bold, fill: color(0xf3f8ff))
label("Classic mouse wheel.", x: 72, y: 324, size: 54, weight: .bold, fill: color(0xf3f8ff))
label("Separate scroll directions on macOS.", x: 75, y: 261, size: 25, weight: .regular, fill: color(0xb9c9d9))

roundRect(NSRect(x: 72, y: 169, width: 243, height: 49), radius: 24, fill: color(0x173a52), stroke: color(0x326988))
label("OPEN SOURCE · SWIFT", x: 92, y: 183, size: 16, weight: .bold, fill: color(0x9ce7ff), tracking: 0.5)
label("github.com/eShok93/ScrollFix", x: 73, y: 76, size: 19, weight: .medium, fill: color(0x8fa5bc))

// Two device cards make the intended outcome legible at social-feed size.
let cardX: CGFloat = 778
roundRect(NSRect(x: cardX, y: 338, width: 419, height: 216), radius: 28, fill: color(0x172636), stroke: color(0x30475d), lineWidth: 2)
roundRect(NSRect(x: cardX, y: 86, width: 419, height: 216), radius: 28, fill: color(0x172636), stroke: color(0x30475d), lineWidth: 2)

roundRect(NSRect(x: 807, y: 397, width: 132, height: 100), radius: 15, fill: color(0x2b455d), stroke: color(0x74a9cf), lineWidth: 3)
roundRect(NSRect(x: 822, y: 411, width: 102, height: 72), radius: 10, fill: color(0x375876))
color(0xa6dfff).setFill()
NSBezierPath(ovalIn: NSRect(x: 850, y: 443, width: 13, height: 13)).fill()
NSBezierPath(ovalIn: NSRect(x: 879, y: 443, width: 13, height: 13)).fill()
label("TRACKPAD", x: 969, y: 461, size: 16, weight: .bold, fill: color(0x92a9bf), tracking: 1)
label("Natural", x: 968, y: 414, size: 29, weight: .bold, fill: color(0xdff7ff))
check(x: 1145, y: 440, fill: color(0x7ad7ff))

let mouse = NSBezierPath(roundedRect: NSRect(x: 834, y: 128, width: 80, height: 126), xRadius: 38, yRadius: 38)
mouse.lineWidth = 3
color(0x74a9cf).setStroke()
color(0x2b455d).setFill()
mouse.fill()
mouse.stroke()
roundRect(NSRect(x: 870, y: 210, width: 8, height: 23), radius: 4, fill: color(0x9ce7ff))
label("MOUSE WHEEL", x: 969, y: 209, size: 16, weight: .bold, fill: color(0x92a9bf), tracking: 1)
label("Classic", x: 968, y: 162, size: 29, weight: .bold, fill: color(0xdff7ff))
check(x: 1145, y: 187, fill: color(0x7ad7ff))

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode social preview")
}
try png.write(to: output)
print("Created \(output.path)")
