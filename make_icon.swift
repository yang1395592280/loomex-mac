import AppKit
import Foundation

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size, flipped: false) { rect in
    let face = NSBezierPath(roundedRect: rect.insetBy(dx: 72, dy: 72), xRadius: 195, yRadius: 195)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
    face.fill()
    NSGraphicsContext.restoreGraphicsState()
    let gradient = NSGradient(starting: NSColor(calibratedWhite: 0.99, alpha: 1), ending: NSColor(calibratedWhite: 0.77, alpha: 1))!
    gradient.draw(in: face, angle: -90)
    let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemCyan, .systemOrange, .systemGreen, .systemIndigo, .systemRed, .systemTeal]
    for index in 0..<9 {
        colors[index].setFill()
        let tile = NSRect(x: 220 + CGFloat(index % 3) * 210, y: 220 + CGFloat(2 - index / 3) * 210, width: 165, height: 165)
        NSBezierPath(roundedRect: tile, xRadius: 37, yRadius: 37).fill()
    }
    return true
}
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
