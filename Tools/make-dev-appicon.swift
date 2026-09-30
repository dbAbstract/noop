#!/usr/bin/env swift
//
// make-dev-appicon.swift <source.png> <dest.png> — tint an app icon for the DEBUG build variant.
//
// FORK-LOCAL. The dev build and the daily-driver build install side by side under different bundle ids,
// and both shipped the same artwork, so the only way to tell them apart on the Home screen was to
// remember which position they were in. This recolours the icon so the dev one is obvious at a glance.
//
// Committed as a GENERATOR rather than only its output so the dev icon can be rebuilt if the base
// artwork ever changes upstream — a hand-edited PNG would silently keep showing the old icon.
//
// CoreImage + AppKit only: no ImageMagick, no PIL, nothing to install. Run:
//   swift Tools/make-dev-appicon.swift  in.png  out.png
//
// A HUE ROTATION would have been the obvious choice and is the wrong one here: the base artwork is
// near-greyscale "machined titanium", and hue rotation on a desaturated pixel does nothing at all. The
// icon would have come out looking identical. CIColorMonochrome instead maps luminance onto a single
// hue, so a greyscale source recolours fully while keeping every edge and highlight of the original.

import Foundation
import CoreImage
import AppKit

// Amber, matching the app's own metricAmber accent — reads as "attention, not error". A red would have
// implied something is broken, which a dev build is not.
let tint = CIColor(red: 0.98, green: 0.58, blue: 0.10)

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make-dev-appicon.swift <source.png> <dest.png>\n".data(using: .utf8)!)
    exit(64)
}
let srcURL = URL(fileURLWithPath: args[1])
let dstURL = URL(fileURLWithPath: args[2])

guard let input = CIImage(contentsOf: srcURL) else {
    FileHandle.standardError.write("✗ could not read \(srcURL.path)\n".data(using: .utf8)!)
    exit(1)
}

guard let mono = CIFilter(name: "CIColorMonochrome") else { exit(1) }
mono.setValue(input, forKey: kCIInputImageKey)
mono.setValue(tint, forKey: kCIInputColorKey)
mono.setValue(1.0, forKey: kCIInputIntensityKey)

// Push contrast back up: monochrome mapping flattens the midtones, and a flat icon reads as a blurry
// smudge at Home-screen size rather than as a recognisable mark.
guard let controls = CIFilter(name: "CIColorControls"), let monoOut = mono.outputImage else { exit(1) }
controls.setValue(monoOut, forKey: kCIInputImageKey)
controls.setValue(1.25, forKey: kCIInputContrastKey)
controls.setValue(0.05, forKey: kCIInputBrightnessKey)

guard let output = controls.outputImage else { exit(1) }

// Render from the SOURCE extent, not the filter's: some CoreImage filters report an infinite extent,
// and createCGImage over that produces either nothing or an enormous allocation.
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
guard let cg = ctx.createCGImage(output, from: input.extent) else {
    FileHandle.standardError.write("✗ render failed\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: cg)
// App Store / asset-catalogue icons must be OPAQUE; an alpha channel makes iconutil and the asset
// compiler reject them. The source is opaque and these filters preserve that, but the PNG writer is
// told explicitly rather than trusted to infer it.
guard let data = rep.representation(using: .png, properties: [.interlaced: false]) else {
    FileHandle.standardError.write("✗ PNG encode failed\n".data(using: .utf8)!)
    exit(1)
}
try data.write(to: dstURL)
print("✓ wrote \(dstURL.lastPathComponent) (\(cg.width)×\(cg.height))")
