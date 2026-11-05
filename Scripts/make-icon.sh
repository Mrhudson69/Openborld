#!/bin/bash
# Draws the app icon and compiles it to .icns.
#
# The artwork is generated from this script rather than stored as a binary, so
# it can be edited in a diff like everything else. Needs only the Command Line
# Tools (swift + iconutil).
set -euo pipefail

OUT="${1:-build/AppIcon.icns}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/draw.swift" <<'SWIFT'
import AppKit

// A rounded-square "cloud layers" mark: three stacked rounded bars suggesting
// stored objects, over a blue gradient in the macOS app-icon silhouette.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons sit in a rounded square inset from the canvas edge.
    let inset = size * 0.085
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237

    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(squircle)
    context.clip()

    let colors = [
        NSColor(calibratedRed: 0.29, green: 0.62, blue: 0.98, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.84, alpha: 1).cgColor,
    ]
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // A soft highlight across the top third, the way Apple's own icons catch light.
    context.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    context.fillEllipse(in: CGRect(
        x: rect.minX - rect.width * 0.25,
        y: rect.midY + rect.height * 0.12,
        width: rect.width * 1.5,
        height: rect.height * 0.9
    ))
    context.restoreGState()

    // Three stacked bars: the layers of stored objects.
    let barWidth = rect.width * 0.52
    let barHeight = rect.height * 0.108
    let gap = barHeight * 0.62
    let totalHeight = barHeight * 3 + gap * 2
    let startY = rect.midY - totalHeight / 2
    let x = rect.midX - barWidth / 2

    let alphas: [CGFloat] = [1.0, 0.82, 0.6]
    for index in 0..<3 {
        let y = startY + CGFloat(2 - index) * (barHeight + gap)
        // Each bar is slightly narrower going down, giving the mark perspective.
        let shrink = CGFloat(index) * barWidth * 0.085
        let barRect = CGRect(
            x: x + shrink / 2,
            y: y,
            width: barWidth - shrink,
            height: barHeight
        )
        let path = CGPath(
            roundedRect: barRect,
            cornerWidth: barHeight / 2,
            cornerHeight: barHeight / 2,
            transform: nil
        )
        context.setFillColor(NSColor.white.withAlphaComponent(alphas[index]).cgColor)
        context.addPath(path)
        context.fillPath()
    }

    return image
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let directory = CommandLine.arguments[1]
for (pixels, name) in sizes {
    let image = drawIcon(size: CGFloat(pixels))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { continue }
    try png.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
}
SWIFT

mkdir -p "$WORK/AppIcon.iconset"
swiftc -O "$WORK/draw.swift" -o "$WORK/draw" 2>/dev/null
"$WORK/draw" "$WORK/AppIcon.iconset"

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$OUT"
echo "✓ Icon written to $OUT"
