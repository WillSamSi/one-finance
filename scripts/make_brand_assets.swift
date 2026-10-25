// Builds the One Finance brand images into the iOS asset catalog (run on a Mac):
//   swift scripts/make_brand_assets.swift
//
// Input:  ../mockups/logo/one-finance-mark.svg  (one path, M/L/Z only, one gradient)
// Output: ios/OneFinance/Assets.xcassets/
//   AppIcon.appiconset/AppIcon-1024.png   opaque Onyx, faint purple halo, the mark at ~71% width
//   WordOne / WordFinance.imageset         the "One Finance" wordmark split in two (splash slides them apart)
//   LaunchWordmark.imageset                the two halves joined pixel for pixel (static launch screen)
//   LaunchBackground.colorset              Onyx #050408
//   ios/OneFinance/OneFinanceMark.swift    the mark's path for SwiftUI

import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let svgURL = root.deletingLastPathComponent().appending(path: "mockups/logo/one-finance-mark.svg")
let assets = root.appending(path: "ios/OneFinance/Assets.xcassets")

// MARK: Path

let svg = try String(contentsOf: svgURL, encoding: .utf8)
guard let dRange = svg.range(of: #" d="([^"]+)""#, options: .regularExpression) else { fatalError("no path in the SVG") }
let d = String(svg[dRange].dropFirst(4).dropLast())

func buildPath(_ d: String) -> CGPath {
    let path = CGMutablePath()
    let scanner = Scanner(string: d)
    scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,\n\t")
    while !scanner.isAtEnd {
        guard let cmd = scanner.scanCharacter() else { break }
        switch cmd {
        case "M", "L":
            guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { fatalError("bad number after \(cmd)") }
            if cmd == "M" { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        case "Z", "z": path.closeSubpath()
        default: fatalError("unexpected command \(cmd)")
        }
    }
    return path
}

let mark = buildPath(d)
let gradientColors = [NSColor(hex: 0xC49BFF).cgColor, NSColor(hex: 0xA45CFF).cgColor, NSColor(hex: 0x8A2BE2).cgColor]
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: gradientColors as CFArray, locations: [0, 0.35, 1])!

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

func bitmap(_ w: Int, _ h: Int, opaque: Bool) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!
}

func writePNG(_ ctx: CGContext, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: App icon (matches app-icon-1024.svg)

do {
    let ctx = bitmap(1024, 1024, opaque: true)
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)  // SVG coordinates: y down
    ctx.setFillColor(NSColor(hex: 0x050408).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    // halo: radial gradient stretched to the 840 x 600 ellipse
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 420, y: 300)
    let halo = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor(hex: 0x2A0B4D, alpha: 0.9).cgColor, NSColor(hex: 0x050408, alpha: 0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1, options: [])
    ctx.restoreGState()
    // the mark: one path, one gradient across it (seamless crossing)
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 2.5259, y: 2.5259)
    ctx.addPath(mark); ctx.clip(using: .winding)
    ctx.drawLinearGradient(gradient, start: CGPoint(x: -248, y: -74.6), end: CGPoint(x: 248, y: 74.6),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    try writePNG(ctx, to: assets.appending(path: "AppIcon.appiconset/AppIcon-1024.png"))
    let contents = """
    {
      "images" : [ { "filename" : "AppIcon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """
    try contents.write(to: assets.appending(path: "AppIcon.appiconset/Contents.json"), atomically: true, encoding: .utf8)
}

// MARK: Wordmark ("One" heavy white, "Finance" semibold Kimoyo with a soft glow; 44pt, -1.2 tracking, 11pt gap)

let pad: CGFloat = 30  // room for the glow
let gap: CGFloat = 11
let size: CGFloat = 44
func attr(_ text: String, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                  .foregroundColor: color, .kern: -1.2])
}
let one = attr("One", weight: .heavy, color: .white)
let fin = attr("Finance", weight: .semibold, color: NSColor(hex: 0xA45CFF))
let textH = ceil(max(one.size().height, fin.size().height))
let heightPt = textH + 2 * pad
let oneW = ceil(pad + one.size().width + gap / 2)
let finW = ceil(gap / 2 + fin.size().width + pad)

func drawText(_ s: NSAttributedString, x: CGFloat, widthPt: CGFloat, scale: CGFloat, glow: Bool) -> CGContext {
    let ctx = bitmap(Int(widthPt * scale), Int(heightPt * scale), opaque: false)
    ctx.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    if glow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(hex: 0xA45CFF, alpha: 0.55)
        shadow.shadowBlurRadius = 20
        shadow.shadowOffset = .zero
        shadow.set()
    }
    s.draw(at: CGPoint(x: x, y: pad))
    NSGraphicsContext.restoreGraphicsState()
    return ctx
}

func imageset(_ name: String, files: [(String, String)]) throws {
    let images = files.map { "{ \"filename\" : \"\($0.0)\", \"idiom\" : \"universal\", \"scale\" : \"\($0.1)\" }" }.joined(separator: ", ")
    let json = "{ \"images\" : [ \(images) ], \"info\" : { \"author\" : \"xcode\", \"version\" : 1 } }\n"
    try json.write(to: assets.appending(path: "\(name).imageset/Contents.json"), atomically: true, encoding: .utf8)
}

for scale: CGFloat in [2, 3] {
    let tag = "@\(Int(scale))x"
    let oneCtx = drawText(one, x: pad, widthPt: oneW, scale: scale, glow: false)
    let finCtx = drawText(fin, x: gap / 2, widthPt: finW, scale: scale, glow: true)
    try writePNG(oneCtx, to: assets.appending(path: "WordOne.imageset/WordOne\(tag).png"))
    try writePNG(finCtx, to: assets.appending(path: "WordFinance.imageset/WordFinance\(tag).png"))
    // The launch image is the two halves side by side, so it matches the splash's first frame exactly.
    let both = bitmap(oneCtx.width + finCtx.width, oneCtx.height, opaque: false)
    both.draw(oneCtx.makeImage()!, in: CGRect(x: 0, y: 0, width: oneCtx.width, height: oneCtx.height))
    both.draw(finCtx.makeImage()!, in: CGRect(x: oneCtx.width, y: 0, width: finCtx.width, height: finCtx.height))
    try writePNG(both, to: assets.appending(path: "LaunchWordmark.imageset/LaunchWordmark\(tag).png"))
}
for name in ["WordOne", "WordFinance", "LaunchWordmark"] {
    try imageset(name, files: [("\(name)@2x.png", "2x"), ("\(name)@3x.png", "3x")])
}

// MARK: Launch background colour

try FileManager.default.createDirectory(at: assets.appending(path: "LaunchBackground.colorset"), withIntermediateDirectories: true)
try """
{ "colors" : [ { "color" : { "color-space" : "srgb", "components" : { "alpha" : "1.000", "red" : "0x05", "green" : "0x04", "blue" : "0x08" } }, "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
""".write(to: assets.appending(path: "LaunchBackground.colorset/Contents.json"), atomically: true, encoding: .utf8)

// MARK: The mark for SwiftUI

let swift = """
// Generated by scripts/make_brand_assets.swift from mockups/logo/one-finance-mark.svg. Don't edit by hand.
import SwiftUI

enum OneFinanceMarkData {
    /// viewBox -248 -74.6 496 149.2; one path (M/L/Z), filled nonzero.
    static let d = "\(d)"
}
"""
try swift.write(to: root.appending(path: "ios/OneFinance/OneFinanceMarkData.swift"), atomically: true, encoding: .utf8)
print("App icon, wordmark (\(Int(oneW + finW)) x \(Int(heightPt)) pt), launch image, colour and mark path written.")
