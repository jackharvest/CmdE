import Cocoa

let sizes = [16, 32, 128, 256, 512]
let iconsetPath = "icon.iconset"

try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(pixelSize: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: pixelSize * 0.22, yRadius: pixelSize * 0.22)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.22, alpha: 1.0),
        NSColor(calibratedRed: 0.93, green: 0.45, blue: 0.13, alpha: 1.0)
    ])
    gradient?.draw(in: bgPath, angle: -90)

    // White folder, with the E showing the gradient through it. The folder is drawn into its
    // own layer so the cut-out only punches through the folder, not the background.
    let layer = NSImage(size: rect.size)
    layer.lockFocus()
    NSColor.white.setFill()
    let radius = pixelSize * 0.05
    NSBezierPath(roundedRect: NSRect(x: pixelSize * 0.16, y: pixelSize * 0.22, width: pixelSize * 0.68, height: pixelSize * 0.5), xRadius: radius, yRadius: radius).fill()
    NSBezierPath(roundedRect: NSRect(x: pixelSize * 0.16, y: pixelSize * 0.6, width: pixelSize * 0.3, height: pixelSize * 0.2), xRadius: radius, yRadius: radius).fill()

    NSGraphicsContext.current?.compositingOperation = .destinationOut
    let stem = pixelSize * 0.075
    let left = pixelSize * 0.385
    let bottom = pixelSize * 0.29
    let height = pixelSize * 0.36
    NSBezierPath(rect: NSRect(x: left, y: bottom, width: stem, height: height)).fill()
    for y in [bottom, bottom + (height - stem) / 2, bottom + height - stem] {
        NSBezierPath(rect: NSRect(x: left, y: y, width: pixelSize * 0.235, height: stem)).fill()
    }
    NSGraphicsContext.current?.compositingOperation = .sourceOver
    layer.unlockFocus()
    layer.draw(in: rect)

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for \(path)")
    }
    FileManager.default.createFile(atPath: path, contents: data)
}

for size in sizes {
    savePNG(renderIcon(pixelSize: CGFloat(size)), to: "\(iconsetPath)/icon_\(size)x\(size).png")
    savePNG(renderIcon(pixelSize: CGFloat(size * 2)), to: "\(iconsetPath)/icon_\(size)x\(size)@2x.png")
}

print("Iconset written to \(iconsetPath)")
