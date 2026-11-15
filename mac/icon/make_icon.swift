// make_icon.swift <version> <out.png>: the icon, as the Android app's (Marko 10.11.2026: "a pure circle, only outline
// white"), on the dark ground, the version under it (version-visible.md). Run by build.sh on GitHub's runner.
import AppKit
let a = CommandLine.arguments
let v = a.count > 1 ? a[1] : "1", out = a.count > 2 ? a[2] : "icon_1024.png"
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1).setFill()
NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185).fill()
let c = NSBezierPath(ovalIn: NSRect(x: 262, y: 300, width: 500, height: 500))
c.lineWidth = 30; NSColor.white.setStroke(); c.stroke()
let p = NSMutableParagraphStyle(); p.alignment = .center
("v" + v as NSString).draw(in: NSRect(x: 100, y: 150, width: 824, height: 110),
    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 84, weight: .bold), .foregroundColor: NSColor(white: 0.75, alpha: 1), .paragraphStyle: p])
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
