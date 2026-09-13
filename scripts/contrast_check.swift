#!/usr/bin/env swift
//
// contrast_check.swift — measure how dark the ink is in a region of a screenshot.
//
// Why this exists: "is this text readable" was judged by eye twice and was wrong both times
// — a deliberately disabled button was reported as a broken one, and an inverted sidebar
// hierarchy was real but only visible after squinting at a crop. This replaces the squinting
// with a number: the darkest ink found in a band, and its contrast against the band's own
// background. A title that is fainter than its caption shows up as a smaller ratio.
//
// Usage: contrast_check.swift <image.png> <x> <y> <w> <h> <label>

import AppKit

func luminance(_ c: NSColor) -> Double {
    func ch(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722 * ch(c.blueComponent)
}

func contrast(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

let a = CommandLine.arguments
guard a.count >= 7 else {
    FileHandle.standardError.write(Data("usage: contrast_check <image.png> <x> <y> <w> <h> <label>\n".utf8))
    exit(2)
}
guard let img = NSImage(contentsOfFile: a[1]), let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("cannot read \(a[1])\n".utf8))
    exit(2)
}

let x0 = Int(a[2]) ?? 0, y0 = Int(a[3]) ?? 0
let w  = Int(a[4]) ?? 0, h = Int(a[5]) ?? 0
let label = a[6]

var lums: [Double] = []
for y in max(0, y0)..<min(rep.pixelsHigh, y0 + h) {
    for x in max(0, x0)..<min(rep.pixelsWide, x0 + w) {
        if let c = rep.colorAt(x: x, y: y) { lums.append(luminance(c)) }
    }
}
guard !lums.isEmpty else { print("\(label): no pixels"); exit(1) }

lums.sort()
// The background is the lightest 20% (a page or panel fill); the ink is the darkest 2%,
// which is the glyph core rather than its antialiased fringe.
let bg = lums[Int(Double(lums.count) * 0.90)]
let ink = lums[Int(Double(lums.count) * 0.02)]

print(String(format: "%@: ink L=%.3f  bg L=%.3f  contrast %.2f:1", label, ink, bg, contrast(ink, bg)))
