#!/usr/bin/env swift
//
// pixel_diff.swift — compare two PNGs and report how different they look.
//
// Why not a byte hash: these screenshots are rendered from live SwiftUI views, so they
// contain a relative timestamp ("Checked: 2 seconds ago") that changes on every run. A
// hash therefore reports drift on every run and is ignored, which is worse than no check.
// What actually matters is whether the images are *visually* the same, so this reports the
// fraction of pixels that differ by more than a just-noticeable amount.
//
// Usage: pixel_diff.swift <a.png> <b.png> [tolerance-percent]
// Exit code 0 when within tolerance, 1 when not, 2 on a usage/load error.

import AppKit
import Foundation

func bitmap(_ path: String) -> NSBitmapImageRep? {
    guard let image = NSImage(contentsOfFile: path), let tiff = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: pixel_diff <a.png> <b.png> [tolerance-percent]\n".utf8))
    exit(2)
}
let tolerance = args.count >= 4 ? (Double(args[3]) ?? 0.5) : 0.5

guard let a = bitmap(args[1]) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(2)
}
guard let b = bitmap(args[2]) else {
    FileHandle.standardError.write(Data("cannot read \(args[2])\n".utf8))
    exit(2)
}

// A size change is never acceptable: it means the layout moved.
guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
    print("size differs: \(a.pixelsWide)x\(a.pixelsHigh) vs \(b.pixelsWide)x\(b.pixelsHigh)")
    exit(1)
}

// Sampling every pixel of a 2720x1732 image is slow in a script; a 2x2 grid sample is
// plenty to tell a redrawn layout from a changed clock.
var differing = 0
var sampled = 0
for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
    for x in stride(from: 0, to: a.pixelsWide, by: 2) {
        sampled += 1
        guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
        let delta = abs(ca.redComponent - cb.redComponent)
            + abs(ca.greenComponent - cb.greenComponent)
            + abs(ca.blueComponent - cb.blueComponent)
        if delta > 0.06 { differing += 1 }
    }
}

let percent = Double(differing) / Double(max(sampled, 1)) * 100
print(String(format: "%.3f%% of sampled pixels differ (tolerance %.2f%%)", percent, tolerance))
exit(percent <= tolerance ? 0 : 1)
