import Cocoa

// Window will be 660x400 points. Render at 2x supersample for crisper text/gradient,
// then downscale to the final 1x PNG (create-dmg has no @2x background convention).
let pointSize = NSSize(width: 660, height: 400)
let scale: CGFloat = 2
let pixelSize = NSSize(width: pointSize.width * scale, height: pointSize.height * scale)

let image = NSImage(size: pixelSize)
image.lockFocus()

let full = NSRect(origin: .zero, size: pixelSize)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.98, green: 0.75, blue: 0.22, alpha: 1.0),
    NSColor(calibratedRed: 0.93, green: 0.45, blue: 0.13, alpha: 1.0)
])
gradient?.draw(in: full, angle: -90)

func drawText(_ string: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: CGFloat, centerY: CGFloat) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = string as NSString
    let textSize = str.size(withAttributes: attrs)
    let rect = NSRect(x: centerX - textSize.width / 2, y: centerY - textSize.height / 2, width: textSize.width, height: textSize.height)
    str.draw(in: rect, withAttributes: attrs)
}

// Title
drawText("CmdE", size: 30 * scale, weight: .heavy, color: .white, centerX: pixelSize.width / 2, centerY: pixelSize.height - 66 * scale)
drawText("Press ⌘E anywhere for a new Finder window.", size: 14 * scale, weight: .medium, color: NSColor.white.withAlphaComponent(0.85), centerX: pixelSize.width / 2, centerY: pixelSize.height - 96 * scale)

// Arrow between the two icon slots (icons sit at x=180 and x=480 in point space, y=210)
let iconCenterY = pointSize.height - 210 // flip: our icons are placed at Finder y=210 from top-left convention used by create-dmg (top-down); NSImage drawing is bottom-up.
let arrowY = iconCenterY * scale
let arrowMidX = (pointSize.width / 2) * scale
let arrowWidth: CGFloat = 90 * scale
let arrowHeight: CGFloat = 26 * scale

let shaftRect = NSRect(x: arrowMidX - arrowWidth / 2, y: arrowY - arrowHeight * 0.14, width: arrowWidth * 0.62, height: arrowHeight * 0.28)
NSColor.white.withAlphaComponent(0.9).setFill()
NSBezierPath(roundedRect: shaftRect, xRadius: shaftRect.height / 2, yRadius: shaftRect.height / 2).fill()

let head = NSBezierPath()
let tipX = arrowMidX + arrowWidth / 2
head.move(to: NSPoint(x: tipX - arrowWidth * 0.34, y: arrowY + arrowHeight / 2))
head.line(to: NSPoint(x: tipX, y: arrowY))
head.line(to: NSPoint(x: tipX - arrowWidth * 0.34, y: arrowY - arrowHeight / 2))
head.close()
NSColor.white.withAlphaComponent(0.9).setFill()
head.fill()

// Footer instructions
drawText("Drag CmdE into Applications, then open it from there.", size: 13 * scale, weight: .semibold, color: NSColor.white.withAlphaComponent(0.85), centerX: pixelSize.width / 2, centerY: 34 * scale)
drawText("Blocked on first launch? System Settings > Privacy & Security > Open Anyway.", size: 11 * scale, weight: .regular, color: NSColor.white.withAlphaComponent(0.65), centerX: pixelSize.width / 2, centerY: 16 * scale)

image.unlockFocus()

// Downscale to final 1x PNG
let finalImage = NSImage(size: pointSize)
finalImage.lockFocus()
image.draw(in: NSRect(origin: .zero, size: pointSize), from: full, operation: .copy, fraction: 1.0)
finalImage.unlockFocus()

guard let tiff = finalImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode background PNG")
}
FileManager.default.createFile(atPath: "dmg_background.png", contents: data)
print("Wrote dmg_background.png (\(Int(pointSize.width))x\(Int(pointSize.height)))")
