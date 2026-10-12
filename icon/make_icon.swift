// draws the Baa app icon: 🐏 on a soft rounded square, Big Sur style
import AppKit
let px = 1024.0
let img = NSImage(size: NSSize(width: px, height: px))
img.lockFocus()
let inset = 100.0, rect = NSRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSShadow().with { $0.shadowColor = .black.withAlphaComponent(0.18); $0.shadowBlurRadius = 24; $0.shadowOffset = NSSize(width: 0, height: -10); $0.set() }
NSGradient(colors: [NSColor(red: 0.80, green: 0.93, blue: 1.00, alpha: 1), NSColor(red: 0.99, green: 0.87, blue: 0.93, alpha: 1)])!.draw(in: shape, angle: -90)
NSShadow().set()
let s = NSAttributedString(string: "🐏", attributes: [.font: NSFont.systemFont(ofSize: 560)])
let sz = s.size()
s.draw(at: NSPoint(x: (px - sz.width) / 2, y: (px - sz.height) / 2 - 10))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
extension NSShadow { func with(_ f: (NSShadow) -> Void) -> NSShadow { f(self); return self } }
