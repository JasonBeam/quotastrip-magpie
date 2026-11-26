#!/usr/bin/env python3
from swiftenv import SWIFTC_CMD
"""Renders the two redesign proposals for the "AI 用量概览" popover.

Design-only: Tests/designs/PanelDesigns.swift is compiled with a tiny harness and
never shipped. Synthetic values mirror the live account (¥50.95 / 累计 ¥20.16 /
今日 3.57M / 缓存 78.6%), no network and no user data are touched.

Output (2x): /tmp/quotastrip-renders/panelv2-{a,b}-{dark,light}.png
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

func render(_ style: PanelV2Style, _ appearance: NSAppearance.Name, _ file: String, folder: URL) {
    let root = PanelV2View(style: style, icon: { name in
        let base = ProcessInfo.processInfo.environment["QS_RES"] ?? ""
        return NSImage(contentsOfFile: base + "/" + name + ".png")
    })
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 640)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = hosting
    window.orderFront(nil)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let size = hosting.fittingSize
    hosting.frame = NSRect(x: 0, y: 0, width: 400, height: size.height)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    guard let rendered = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { exit(2) }
    hosting.cacheDisplay(in: hosting.bounds, to: rendered)
    // SwiftUI 视图透明：铺当前外观的窗口底色，才是真实观感。
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rendered.pixelsWide,
                               pixelsHigh: rendered.pixelsHigh, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = hosting.bounds.size
    NSGraphicsContext.saveGraphicsState()
    if let appearance = NSAppearance(named: appearance) {
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
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(3) }
    try! png.write(to: folder.appendingPathComponent(file))
    print(file, rep.pixelsWide, "x", rep.pixelsHigh, "fitting", size)
}

let app = NSApplication.shared
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for style in PanelV2Style.allCases {
    let tag = style == .heroTabbed ? "a" : "b"
    render(style, .darkAqua, "panelv2-" + tag + "-dark.png", folder: folder)
    render(style, .aqua, "panelv2-" + tag + "-light.png", folder: folder)
}
'''


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="quotastrip-panelv2-") as folder:
        work = pathlib.Path(folder)
        (work / "PanelDesigns.swift").write_text(
            (DESIGNS / "PanelDesigns.swift").read_text(encoding="utf-8"), encoding="utf-8")
        (work / "main.swift").write_text(MAIN, encoding="utf-8")
        binary = work / "panelv2-render"
        build = subprocess.run(
            [*SWIFTC_CMD, "-swift-version", "5", "-target", "arm64-apple-macosx11.0",
             str(work / "PanelDesigns.swift"), str(work / "main.swift"),
             "-o", str(binary), "-framework", "AppKit", "-framework", "SwiftUI"],
            capture_output=True, text=True, timeout=420)
        if build.returncode != 0:
            sys.stderr.write(build.stdout + build.stderr)
            return 1
        output = work / "out"
        output.mkdir()
        run = subprocess.run([str(binary), str(output)],
                             env={"QS_RES": str(ROOT / "Resources"), "PATH": "/usr/bin:/bin"},
                             capture_output=True, text=True, timeout=180)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if run.returncode != 0:
            return run.returncode
        keeps = pathlib.Path("/tmp/quotastrip-renders")
        keeps.mkdir(exist_ok=True)
        for png in output.glob("*.png"):
            (keeps / png.name).write_bytes(png.read_bytes())
        print("wrote", keeps)
    print("PASS: panel v2 renders")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
