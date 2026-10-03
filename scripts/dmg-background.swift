// Renders the DMG window background: an arrow from the app icon to Applications and a
// one-line hint. Layout constants must match scripts/make-dmg.sh.
//   swift scripts/dmg-background.swift <out.png> <scale>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let scale = Double(args[2]) else {
    FileHandle.standardError.write("usage: dmg-background.swift <out.png> <scale>\n".data(using: .utf8)!)
    exit(2)
}

let width = 640.0, height = 400.0
let iconY = 190.0 // icon centre, measured from the top (Finder's coordinates)
let leftX = 170.0, rightX = 470.0

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: width, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Soft warm gradient, light enough for Finder's dark icon labels.
NSGradient(
    starting: NSColor(srgbRed: 1.00, green: 0.98, blue: 0.95, alpha: 1),
    ending: NSColor(srgbRed: 0.99, green: 0.91, blue: 0.84, alpha: 1)
)!.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

// Arrow between the icons (AppKit's y axis points up).
let y = height - iconY
let arrowColor = NSColor(srgbRed: 0.93, green: 0.50, blue: 0.30, alpha: 0.85)
arrowColor.setStroke()
arrowColor.setFill()
let shaftStart = leftX + 90, shaftEnd = rightX - 100
let shaft = NSBezierPath()
shaft.move(to: NSPoint(x: shaftStart, y: y))
shaft.line(to: NSPoint(x: shaftEnd, y: y))
shaft.lineWidth = 6
shaft.lineCapStyle = .round
let dash: [CGFloat] = [0.1, 14]
shaft.setLineDash(dash, count: 2, phase: 0)
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: shaftEnd + 18, y: y))
head.line(to: NSPoint(x: shaftEnd - 4, y: y + 14))
head.line(to: NSPoint(x: shaftEnd - 4, y: y - 14))
head.close()
head.fill()

// Hint under the icons.
let style = NSMutableParagraphStyle()
style.alignment = .center
let hint = NSAttributedString(string: "Drag Sunshine to Applications to install", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.35, green: 0.27, blue: 0.24, alpha: 1),
    .paragraphStyle: style,
])
hint.draw(in: NSRect(x: 0, y: 70, width: width, height: 24))

NSGraphicsContext.restoreGraphicsState()

let url = URL(filePath: args[1])
try rep.representation(using: .png, properties: [:])!.write(to: url)
