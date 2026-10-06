import AppKit

// Renders CaffeinateBar's 1024x1024 icon source: warm espresso gradient
// squircle + cream SF Symbol coffee cup (cup.and.saucer.fill).
// Usage: swift make-icon.swift  (writes icon-1024.png next to this script)

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: S, height: S).fill() // transparent canvas

// Background squircle with vertical espresso gradient (corners stay transparent).
let bgRect = NSRect(x: 0, y: 0, width: S, height: S)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: S * 0.24, yRadius: S * 0.24)
let top = NSColor(srgbRed: 0.47, green: 0.30, blue: 0.17, alpha: 1.0)    // latte
let bottom = NSColor(srgbRed: 0.23, green: 0.13, blue: 0.08, alpha: 1.0) // espresso
NSGradient(colors: [top, bottom])!.draw(in: bg, angle: 90)

// Soft top-light sheen, clipped to the squircle so no edges show.
NSGraphicsContext.saveGraphicsState()
bg.setClip()
let sheenTop = NSColor(white: 1.0, alpha: 0.14)
let sheenBottom = NSColor(white: 1.0, alpha: 0.0)
// angle 90 lays the first color at the bottom, so list clear first:
// transparent at the rect's lower edge (no visible line), light at top.
NSGradient(colors: [sheenBottom, sheenTop])!.draw(
    in: NSRect(x: 0, y: S * 0.45, width: S, height: S * 0.55), angle: 90)
NSGraphicsContext.restoreGraphicsState()

// Cream coffee glyph, centered with a soft drop shadow.
if let sym = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil),
   let configured = sym.withSymbolConfiguration(
       NSImage.SymbolConfiguration(pointSize: S * 0.50, weight: .medium)) {
    let tinted = NSImage(size: configured.size)
    tinted.lockFocus()
    NSColor(srgbRed: 1.0, green: 0.94, blue: 0.84, alpha: 1.0).set()
    let r = NSRect(origin: .zero, size: configured.size)
    r.fill()
    configured.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
    tinted.unlockFocus()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0.0, alpha: 0.35)
    shadow.shadowBlurRadius = S * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -S * 0.015)
    shadow.set()

    let origin = NSPoint(x: (S - configured.size.width) / 2,
                         y: (S - configured.size.height) / 2 - S * 0.01)
    tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSShadow().set() // clear
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("ERROR: failed to render PNG\n", stderr)
    exit(1)
}
let out = URL(fileURLWithPath: "icon-1024.png")
try png.write(to: out)
print("Wrote \(out.path) (\(png.count) bytes)")
