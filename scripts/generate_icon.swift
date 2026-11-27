#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Generates a crisp Apple-style frosted-glass AppIcon.icns for Pliw Face
// with the unified Pliw App ("P.") bottom-right corner badge.
let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "Resources/AppIcon.icns"
let previewPngPath = args.count > 2 ? args[2] : nil

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // 1. Standard macOS squircle (84% of canvas, centered) with soft drop shadow
    let innerSize = s * 0.84
    let inset = (s - innerSize) * 0.5
    let cardRect = CGRect(x: inset, y: inset, width: innerSize, height: innerSize)
    let cardRadius = innerSize * 0.225
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.014),
        blur: s * 0.028,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.24)
    )
    ctx.addPath(cardPath)
    ctx.setFillColor(CGColor(red: 0.06, green: 0.45, blue: 0.42, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Luminous Apple-style Emerald -> Teal -> Deep Ocean Teal gradient background
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()

    let bgColors = [
        CGColor(red: 0.20, green: 0.85, blue: 0.52, alpha: 1.0), // #33D985 vibrant emerald top-left
        CGColor(red: 0.08, green: 0.72, blue: 0.65, alpha: 1.0), // #14B8A6 luminous teal center
        CGColor(red: 0.05, green: 0.36, blue: 0.44, alpha: 1.0)  // #0D5C70 deep ocean teal bottom-right
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.52, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
            options: []
        )
    }

    // Soft top-left specular radial glow
    let glowColors = [
        CGColor(red: 0.82, green: 1.0, blue: 0.92, alpha: 0.34),
        CGColor(red: 0.82, green: 1.0, blue: 0.92, alpha: 0.0)
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: cardRect.minX + innerSize * 0.24, y: cardRect.maxY - innerSize * 0.18),
            startRadius: 0,
            endCenter: CGPoint(x: cardRect.minX + innerSize * 0.24, y: cardRect.maxY - innerSize * 0.18),
            endRadius: innerSize * 0.68,
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle inner rim highlight on squircle
    ctx.saveGState()
    let rimPath = CGPath(
        roundedRect: cardRect.insetBy(dx: s * 0.005, dy: s * 0.005),
        cornerWidth: cardRadius * 0.98,
        cornerHeight: cardRadius * 0.98,
        transform: nil
    )
    ctx.addPath(rimPath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.26))
    ctx.setLineWidth(max(1.0, s * 0.008))
    ctx.strokePath()
    ctx.restoreGState()

    // 3. Crisp Frosted-Glass Apple Face ID Emblem (centered slightly upper-left to balance "P." badge)
    let glyphBox = innerSize * 0.54
    let gx = cardRect.midX - glyphBox * 0.52
    let gy = cardRect.midY - glyphBox * 0.48
    let gRect = CGRect(x: gx, y: gy, width: glyphBox, height: glyphBox)

    let strokeW = max(1.6, glyphBox * 0.095)
    let cornerLen = glyphBox * 0.26
    let cornerR = glyphBox * 0.13

    func drawFaceIDStrokes() {
        // 4 rounded viewfinder corner brackets
        let brackets = CGMutablePath()

        // Top-left
        brackets.move(to: CGPoint(x: gRect.minX, y: gRect.maxY - cornerLen))
        brackets.addArc(tangent1End: CGPoint(x: gRect.minX, y: gRect.maxY),
                        tangent2End: CGPoint(x: gRect.minX + cornerLen, y: gRect.maxY),
                        radius: cornerR)
        brackets.addLine(to: CGPoint(x: gRect.minX + cornerLen, y: gRect.maxY))

        // Top-right
        brackets.move(to: CGPoint(x: gRect.maxX - cornerLen, y: gRect.maxY))
        brackets.addArc(tangent1End: CGPoint(x: gRect.maxX, y: gRect.maxY),
                        tangent2End: CGPoint(x: gRect.maxX, y: gRect.maxY - cornerLen),
                        radius: cornerR)
        brackets.addLine(to: CGPoint(x: gRect.maxX, y: gRect.maxY - cornerLen))

        // Bottom-right
        brackets.move(to: CGPoint(x: gRect.maxX, y: gRect.minY + cornerLen))
        brackets.addArc(tangent1End: CGPoint(x: gRect.maxX, y: gRect.minY),
                        tangent2End: CGPoint(x: gRect.maxX - cornerLen, y: gRect.minY),
                        radius: cornerR)
        brackets.addLine(to: CGPoint(x: gRect.maxX - cornerLen, y: gRect.minY))

        // Bottom-left
        brackets.move(to: CGPoint(x: gRect.minX + cornerLen, y: gRect.minY))
        brackets.addArc(tangent1End: CGPoint(x: gRect.minX, y: gRect.minY),
                        tangent2End: CGPoint(x: gRect.minX, y: gRect.minY + cornerLen),
                        radius: cornerR)
        brackets.addLine(to: CGPoint(x: gRect.minX, y: gRect.minY + cornerLen))

        // Eyes (2 vertical rounded bars)
        let eyeYTop = gRect.minY + glyphBox * 0.67
        let eyeYBot = gRect.minY + glyphBox * 0.56
        let eyeOffsetX = glyphBox * 0.19
        brackets.move(to: CGPoint(x: gRect.midX - eyeOffsetX, y: eyeYTop))
        brackets.addLine(to: CGPoint(x: gRect.midX - eyeOffsetX, y: eyeYBot))
        brackets.move(to: CGPoint(x: gRect.midX + eyeOffsetX, y: eyeYTop))
        brackets.addLine(to: CGPoint(x: gRect.midX + eyeOffsetX, y: eyeYBot))

        // Nose (vertical stem with gentle hook at bottom)
        let noseTop = gRect.minY + glyphBox * 0.67
        let noseBot = gRect.minY + glyphBox * 0.44
        brackets.move(to: CGPoint(x: gRect.midX, y: noseTop))
        brackets.addLine(to: CGPoint(x: gRect.midX, y: noseBot + glyphBox * 0.04))
        brackets.addQuadCurve(
            to: CGPoint(x: gRect.midX - glyphBox * 0.06, y: noseBot),
            control: CGPoint(x: gRect.midX, y: noseBot)
        )

        // Friendly smile arc
        let smileY = gRect.minY + glyphBox * 0.30
        let smileHalfW = glyphBox * 0.19
        brackets.move(to: CGPoint(x: gRect.midX - smileHalfW, y: smileY))
        brackets.addQuadCurve(
            to: CGPoint(x: gRect.midX + smileHalfW, y: smileY),
            control: CGPoint(x: gRect.midX, y: smileY - glyphBox * 0.12)
        )

        ctx.addPath(brackets)
        ctx.setLineWidth(strokeW)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    // Soft glass shadow behind Face ID glyph
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.014),
        blur: s * 0.028,
        color: CGColor(red: 0.02, green: 0.18, blue: 0.16, alpha: 0.36)
    )
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.96))
    drawFaceIDStrokes()
    ctx.restoreGState()

    // 4. Unified Pliw App ("P.") bottom-right corner badge (26% size, 0.05 inset)
    let badgeSize = s * 0.26
    let badgeInset = s * 0.05
    let badgeRect = CGRect(
        x: s - badgeInset - badgeSize,
        y: badgeInset,
        width: badgeSize,
        height: badgeSize
    )
    let badgeCorner = badgeSize * 0.25
    let borderW = max(2.0, badgeSize * 0.065)

    // White cutout ring + soft shadow
    ctx.saveGState()
    let ringRect = badgeRect.insetBy(dx: -borderW * 0.5, dy: -borderW * 0.5)
    let ringPath = CGPath(
        roundedRect: ringRect,
        cornerWidth: badgeCorner + borderW * 0.35,
        cornerHeight: badgeCorner + borderW * 0.35,
        transform: nil
    )
    ctx.setShadow(
        offset: CGSize(width: 0, height: -badgeSize * 0.045),
        blur: badgeSize * 0.12,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.42)
    )
    ctx.addPath(ringPath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.fillPath()
    ctx.restoreGState()

    // Dark macOS squircle fill
    ctx.saveGState()
    let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: badgeCorner, cornerHeight: badgeCorner, transform: nil)
    ctx.addPath(badgePath)
    ctx.clip()
    let badgeGradCols = [
        CGColor(red: 0x2c / 255.0, green: 0x2c / 255.0, blue: 0x2e / 255.0, alpha: 1.0),
        CGColor(red: 0x14 / 255.0, green: 0x14 / 255.0, blue: 0x16 / 255.0, alpha: 1.0)
    ] as CFArray
    if let bg = CGGradient(colorsSpace: colorSpace, colors: badgeGradCols, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            bg,
            start: CGPoint(x: badgeRect.midX, y: badgeRect.maxY),
            end: CGPoint(x: badgeRect.midX, y: badgeRect.minY),
            options: []
        )
    }
    ctx.restoreGState()

    // Subtle inner rim on badge
    ctx.saveGState()
    let bRim = CGPath(
        roundedRect: badgeRect.insetBy(dx: badgeSize * 0.015, dy: badgeSize * 0.015),
        cornerWidth: badgeCorner * 0.94,
        cornerHeight: badgeCorner * 0.94,
        transform: nil
    )
    ctx.addPath(bRim)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.setLineWidth(max(1.0, badgeSize * 0.02))
    ctx.strokePath()
    ctx.restoreGState()

    // Geometric "P." monogram inside badge
    func mapPt(_ svgX: CGFloat, _ svgY: CGFloat) -> CGPoint {
        CGPoint(
            x: badgeRect.minX + (svgX / 64.0) * badgeSize,
            y: badgeRect.minY + (1.0 - svgY / 64.0) * badgeSize
        )
    }
    ctx.saveGState()
    let pPath = CGMutablePath()
    pPath.move(to: mapPt(22.5, 45.0))
    pPath.addLine(to: mapPt(22.5, 19.5))
    pPath.addLine(to: mapPt(34.5, 19.5))
    pPath.addCurve(to: mapPt(44.0, 28.2), control1: mapPt(40.2, 19.5), control2: mapPt(44.0, 23.0))
    pPath.addCurve(to: mapPt(34.5, 36.8), control1: mapPt(44.0, 33.4), control2: mapPt(40.2, 36.8))
    pPath.addLine(to: mapPt(22.5, 36.8))

    ctx.addPath(pPath)
    ctx.setStrokeColor(CGColor(red: 0xf5 / 255.0, green: 0xf5 / 255.0, blue: 0xf7 / 255.0, alpha: 1.0))
    ctx.setLineWidth(max(1.2, badgeSize * (5.2 / 64.0)))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    if size >= 32 {
        let dotC = mapPt(43.0, 43.2)
        let dotR = badgeSize * (3.0 / 64.0)
        ctx.setFillColor(CGColor(red: 0xa1 / 255.0, green: 0xa1 / 255.0, blue: 0xa6 / 255.0, alpha: 1.0))
        ctx.fillEllipse(in: CGRect(x: dotC.x - dotR, y: dotC.y - dotR, width: dotR * 2, height: dotR * 2))
    }
    ctx.restoreGState()

    guard let cgImg = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: cgImg)
    return rep.representation(using: .png, properties: [:])
}

let tmpIconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PliwFace.iconset")
try? FileManager.default.removeItem(at: tmpIconset)
try FileManager.default.createDirectory(at: tmpIconset, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    if let png = renderIcon(size: px) {
        try png.write(to: tmpIconset.appendingPathComponent(name))
        if px == 512, let previewPngPath = previewPngPath {
            try png.write(to: URL(fileURLWithPath: previewPngPath))
        }
    }
}

let outURL = URL(fileURLWithPath: outPath)
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tmpIconset.path, "-o", outURL.path]
try proc.run()
proc.waitUntilExit()
try? FileManager.default.removeItem(at: tmpIconset)

if proc.terminationStatus == 0 {
    print("✅ Generated icon at \(outURL.path)")
} else {
    fputs("❌ iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}
