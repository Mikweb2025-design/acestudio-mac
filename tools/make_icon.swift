// Renders AppIcon.icns: rounded gradient square with a waveform symbol.
import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 1, green: 0.27, blue: 0.45, alpha: 1), NSColor(red: 0.45, green: 0.2, blue: 0.95, alpha: 1)])!
        .draw(in: path, angle: -45)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .bold).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let sz = sym.size
        sym.draw(in: NSRect(x: (s - sz.width) / 2, y: (s - sz.height) / 2, width: sz.width, height: sz.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for p in sizes where p <= 512 {
    try! render(p).write(to: dir.appendingPathComponent("icon_\(p)x\(p).png"))
    try! render(p * 2).write(to: dir.appendingPathComponent("icon_\(p)x\(p)@2x.png"))
}
let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
t.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]; try! t.run(); t.waitUntilExit()
try? FileManager.default.removeItem(at: dir)
