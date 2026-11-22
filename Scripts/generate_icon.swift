import AppKit
import CoreGraphics
import Foundation

// Renders a minimalist Zen macOS app icon for Graphe directly into an .icns file.
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate_icon.swift <output.icns>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

// Standard Apple ICNS PNG OSTypes (16px through 1024px Retina)
let icnsEntries: [(ostype: String, px: Int)] = [
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic13", 256),
    ("ic08", 256),
    ("ic14", 512),
    ("ic09", 512),
    ("ic10", 1024)
]

func drawIcon(size: CGFloat) -> CGImage? {
    let px = Int(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // 1. macOS Big Sur+ squircle canvas inset (~10% margin)
    let inset = size * 0.095
    let cardRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = cardRect.width * 0.225
    let squircle = CGPath(roundedRect: cardRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Soft outer drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.018), blur: size * 0.04, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Deep obsidian-slate gradient inside squircle
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bgColors = [
        NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.22, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0).cgColor
    ] as CFArray
    if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: size * 0.5, y: cardRect.maxY),
            end: CGPoint(x: size * 0.5, y: cardRect.minY),
            options: []
        )
    }

    // Subtle warm inner border highlight
    ctx.addPath(squircle)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.94, green: 0.89, blue: 0.78, alpha: 0.16).cgColor)
    ctx.setLineWidth(max(1.0, size * 0.012))
    ctx.strokePath()

    // 2. Minimalist open philosophy book (warm parchment pages)
    let cx = size * 0.5
    let bookBottom = size * 0.30
    let bookTop = size * 0.67
    let halfW = size * 0.265
    let spineDip = size * 0.032

    // Left page
    let leftPage = CGMutablePath()
    leftPage.move(to: CGPoint(x: cx - size * 0.012, y: bookBottom + spineDip))
    leftPage.addQuadCurve(
        to: CGPoint(x: cx - halfW, y: bookBottom),
        control: CGPoint(x: cx - halfW * 0.52, y: bookBottom + spineDip * 1.4)
    )
    leftPage.addLine(to: CGPoint(x: cx - halfW, y: bookTop))
    leftPage.addQuadCurve(
        to: CGPoint(x: cx - size * 0.012, y: bookTop - spineDip * 0.8),
        control: CGPoint(x: cx - halfW * 0.52, y: bookTop + spineDip * 0.9)
    )
    leftPage.closeSubpath()

    // Right page
    let rightPage = CGMutablePath()
    rightPage.move(to: CGPoint(x: cx + size * 0.012, y: bookBottom + spineDip))
    rightPage.addQuadCurve(
        to: CGPoint(x: cx + halfW, y: bookBottom),
        control: CGPoint(x: cx + halfW * 0.52, y: bookBottom + spineDip * 1.4)
    )
    rightPage.addLine(to: CGPoint(x: cx + halfW, y: bookTop))
    rightPage.addQuadCurve(
        to: CGPoint(x: cx + size * 0.012, y: bookTop - spineDip * 0.8),
        control: CGPoint(x: cx + halfW * 0.52, y: bookTop + spineDip * 0.9)
    )
    rightPage.closeSubpath()

    ctx.setFillColor(NSColor(calibratedRed: 0.95, green: 0.91, blue: 0.82, alpha: 0.96).cgColor)
    ctx.addPath(leftPage)
    ctx.fillPath()

    ctx.setFillColor(NSColor(calibratedRed: 0.90, green: 0.85, blue: 0.75, alpha: 0.96).cgColor)
    ctx.addPath(rightPage)
    ctx.fillPath()

    // Subtle editorial text lines on left page
    let lineColor = NSColor(calibratedRed: 0.25, green: 0.22, blue: 0.18, alpha: 0.28).cgColor
    ctx.setStrokeColor(lineColor)
    ctx.setLineWidth(max(1.0, size * 0.014))
    ctx.setLineCap(.round)
    for row in 0..<4 {
        let y = bookTop - size * (0.095 + CGFloat(row) * 0.055)
        let x1 = cx - halfW + size * 0.048
        let x2 = cx - size * 0.055 - (row == 3 ? size * 0.05 : 0)
        ctx.move(to: CGPoint(x: x1, y: y))
        ctx.addLine(to: CGPoint(x: x2, y: y))
        ctx.strokePath()
    }

    // Warm golden highlight stroke on right page (signature academic highlight!)
    ctx.setStrokeColor(NSColor(calibratedRed: 0.92, green: 0.72, blue: 0.24, alpha: 0.92).cgColor)
    ctx.setLineWidth(max(1.5, size * 0.032))
    let hlY = bookTop - size * 0.15
    ctx.move(to: CGPoint(x: cx + size * 0.052, y: hlY))
    ctx.addLine(to: CGPoint(x: cx + halfW - size * 0.052, y: hlY))
    ctx.strokePath()

    // Editorial lines below highlight on right page
    ctx.setStrokeColor(lineColor)
    ctx.setLineWidth(max(1.0, size * 0.014))
    for row in [0, 2, 3] {
        let y = bookTop - size * (0.095 + CGFloat(row) * 0.055)
        let x1 = cx + size * 0.052
        let x2 = cx + halfW - size * 0.052 - (row == 3 ? size * 0.04 : 0)
        ctx.move(to: CGPoint(x: x1, y: y))
        ctx.addLine(to: CGPoint(x: x2, y: y))
        ctx.strokePath()
    }

    // Crimson/terracotta silk bookmark ribbon draping cleanly from top center
    let ribbonW = size * 0.052
    let ribbonTop = bookTop + size * 0.05
    let ribbonBottom = bookTop - size * 0.11
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: cx - ribbonW * 0.5, y: ribbonTop))
    ribbon.addLine(to: CGPoint(x: cx + ribbonW * 0.5, y: ribbonTop))
    ribbon.addLine(to: CGPoint(x: cx + ribbonW * 0.5, y: ribbonBottom))
    ribbon.addLine(to: CGPoint(x: cx, y: ribbonBottom + size * 0.025))
    ribbon.addLine(to: CGPoint(x: cx - ribbonW * 0.5, y: ribbonBottom))
    ribbon.closeSubpath()

    ctx.setFillColor(NSColor(calibratedRed: 0.82, green: 0.34, blue: 0.28, alpha: 0.96).cgColor)
    ctx.addPath(ribbon)
    ctx.fillPath()

    ctx.restoreGState()
    return ctx.makeImage()
}

var pngCache: [Int: Data] = [:]
var body = Data()

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

for entry in icnsEntries {
    let png: Data
    if let cached = pngCache[entry.px] {
        png = cached
    } else {
        guard let cgImg = drawIcon(size: CGFloat(entry.px)) else {
            fputs("Failed to render \(entry.px)px\n", stderr)
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cgImg)
        guard let encoded = rep.representation(using: .png, properties: [:]) else {
            fputs("Failed to encode \(entry.px)px\n", stderr)
            exit(1)
        }
        pngCache[entry.px] = encoded
        png = encoded
    }
    body.append(contentsOf: entry.ostype.utf8)
    appendUInt32BE(UInt32(8 + png.count), to: &body)
    body.append(png)
}

var icnsData = Data("icns".utf8)
appendUInt32BE(UInt32(8 + body.count), to: &icnsData)
icnsData.append(body)

try icnsData.write(to: outputURL, options: .atomic)
print("Generated AppIcon.icns (\(icnsData.count) bytes) at \(outputURL.path)")
