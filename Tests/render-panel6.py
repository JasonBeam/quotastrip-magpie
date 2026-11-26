#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders the token-receipt style status-bar panel (paper + POS) at 2x.

Design-only: compiles Tests/designs/PanelDesigns6.swift with real NSHostingView, no
network, no Keychain, nothing outside a temp dir.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DESIGNS = ROOT / "Tests" / "designs"

MAIN = r'''
import AppKit
import SwiftUI

let app = NSApplication.shared

func render(_ style: Panel6Style, _ appearance: NSAppearance.Name, _ file: String, folder: URL) {
    let view = NSHostingView(rootView: Panel6View(style: style))
    view.appearance = NSAppearance(named: appearance)
    view.frame = NSRect(x: 0, y: 0, width: 330, height: 100)
    view.layoutSubtreeIfNeeded()
    let fit = view.fittingSize
    view.frame = NSRect(x: 0, y: 0, width: fit.width, height: fit.height)
    view.layoutSubtreeIfNeeded()

    guard let rendered = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
    view.cacheDisplay(in: view.bounds, to: rendered)

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rendered.pixelsWide,
                               pixelsHigh: rendered.pixelsHigh, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // 面板外框：纸色/黑底两种情况都铺一层窗口底色，避免透明底影响观感判断。
    (style == .paper ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.10, alpha: 1)).setFill()
    view.bounds.fill()
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(rendered)
    image.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1,
               respectFlipped: true, hints: nil)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    try! png.write(to: folder.appendingPathComponent(file))
    print(file, rep.pixelsWide, "x", rep.pixelsHigh)
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let names = ["panel6-0-paper", "panel6-1-pos"]
for (index, style) in Panel6Style.allCases.enumerated() {
    for appearance in [NSAppearance.Name.darkAqua, .aqua] {
        let suffix = appearance == .darkAqua ? "dark" : "light"
        render(style, appearance, names[index] + "-" + suffix + ".png", folder: folder)
    }
}
'''


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="quotastrip-panel6-") as folder:
        work = pathlib.Path(folder)
        (work / "PanelDesigns6.swift").write_text(
            (DESIGNS / "PanelDesigns6.swift").read_text(encoding="utf-8"), encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        binary = work / "panel6-render"
        build = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0",
             str(work / "PanelDesigns6.swift"), str(work / "main.swift"),
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
