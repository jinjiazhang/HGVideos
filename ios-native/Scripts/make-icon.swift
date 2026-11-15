import AppKit
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(calibratedRed: 0.08, green: 0.25, blue: 0.24, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
NSColor(calibratedRed: 0.83, green: 0.89, blue: 0.80, alpha: 1).setStroke()
let frame = NSBezierPath(roundedRect: NSRect(x: 220, y: 215, width: 584, height: 594), xRadius: 110, yRadius: 110)
frame.lineWidth = 30; frame.stroke()
NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.82, alpha: 1).setFill()
let triangle = NSBezierPath()
triangle.move(to: NSPoint(x: 430, y: 350)); triangle.line(to: NSPoint(x: 430, y: 675)); triangle.line(to: NSPoint(x: 680, y: 512)); triangle.close(); triangle.fill()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
