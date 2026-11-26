#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders five big-type panel layouts with real SwiftUI (NSHostingView).

Each variant is laid out at its natural size, rendered at 2x on the window
background of the requested appearance, then stacked into one sheet per
appearance. Synthetic data only: no network, no disk reads outside the repo.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"
DESIGNS = ROOT / "Tests" / "designs"

MAIN = r'''
import AppKit
import SwiftUI

let app = NSApplication.shared

func render(_ style: Panel3Style, appearance name: NSAppearance.Name) -> NSBitmapImageRep {
    let hosting = NSHostingView(rootView: Panel3View(style: style))
    hosting.appearance = NSAppearance(named: name)
    hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
    hosting.layoutSubtreeIfNeeded()

    guard let rendered = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(2) }
    hosting.cacheDisplay(in: hosting.bounds, to: rendered)

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rendered.pixelsWide,
                               pixelsHigh: rendered.pixelsHigh, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = hosting.bounds.size
    NSGraphicsContext.saveGraphicsState()
    if let appearance = NSAppearance(named: name) {
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.windowBackgroundColor.setFill()
            hosting.bounds.fill()
            let image = NSImage(size: hosting.bounds.size)
            image.addRepresentation(rendered)
            image.draw(in: hosting.bounds, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    return rep
}

final class Sheet: NSView {
    var images: [NSImage] = []
    var labels: [String] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        var y: CGFloat = 8
        for (index, image) in images.enumerated() {
            let label = NSAttributedString(string: labels[index], attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            label.draw(at: NSPoint(x: 8, y: y))
            y += 16
            image.draw(in: NSRect(x: 8, y: y, width: image.size.width, height: image.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            y += image.size.height + 16
        }
    }
    override var isOpaque: Bool { true }
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for appearance in [NSAppearance.Name.darkAqua, NSAppearance.Name.aqua] {
    let suffix = appearance == .darkAqua ? "dark" : "light"
    var reps: [(String, NSBitmapImageRep)] = []
    for style in Panel3Style.allCases {
        let rep = render(style, appearance: appearance)
        reps.append(("panel3-\(style.rawValue)-\(style)-\(suffix)", rep))
        try! rep.representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent("panel3-\(style.rawValue)-\(style)-\(suffix).png"))
        print("panel3-\(style.rawValue)-\(style)-\(suffix)", rep.pixelsWide, "x", rep.pixelsHigh)
    }
    let width = reps.map { CGFloat($0.1.pixelsWide) / 2 }.max() ?? 400
    let height = reps.reduce(CGFloat(0)) { $0 + CGFloat($1.1.pixelsHigh) / 2 + 32 } + 8
    let sheet = Sheet(frame: NSRect(x: 0, y: 0, width: width + 16, height: height))
    sheet.images = reps.map { entry in
        let image = NSImage(size: NSSize(width: CGFloat(entry.1.pixelsWide) / 2,
                                         height: CGFloat(entry.1.pixelsHigh) / 2))
        image.addRepresentation(entry.1)
        return image
    }
    sheet.labels = reps.map { $0.0 }
    guard let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { exit(4) }
    sheet.cacheDisplay(in: sheet.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: folder.appendingPathComponent("panel3-sheet-\(suffix).png"))
    print("panel3-sheet-\(suffix)", rep.pixelsWide, rep.pixelsHigh)
}
'''


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="quotastrip-panel3-") as folder:
        work = pathlib.Path(folder)
        (work / "PanelDesigns3.swift").write_text(
            (DESIGNS / "PanelDesigns3.swift").read_text(encoding="utf-8"), encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        binary = work / "panel3-render"
        build = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0",
             str(work / "PanelDesigns3.swift"), str(work / "main.swift"),
             "-o", str(binary), "-framework", "AppKit", "-framework", "SwiftUI"],
            capture_output=True, text=True, timeout=420)
        if build.returncode != 0:
            sys.stderr.write(build.stdout + build.stderr)
            return 1
        output = work / "out"
        output.mkdir()
        run = subprocess.run([str(binary), str(output)], capture_output=True, text=True, timeout=180)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if run.returncode != 0:
            return run.returncode
        keeps = pathlib.Path("/tmp/quotastrip-renders")
        keeps.mkdir(exist_ok=True)
        for png in output.glob("*.png"):
            (keeps / png.name).write_bytes(png.read_bytes())
        print("wrote", keeps)
    print("PASS: panel design renders")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
