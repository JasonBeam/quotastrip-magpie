"""选 swiftc 和 SDK。

Liquid Glass 的 NSGlassEffectView 只有 macOS 26 起的 SDK 才有，CommandLineTools
自带的 SDK 太旧，编译 Sources 会直接失败。有 Xcode 就用 Xcode 的 toolchain+SDK，
没有就退回系统默认，让降级路径仍能编译。
"""

import os

XCODE = "/Applications/Xcode.app/Contents/Developer"
TOOLCHAIN = XCODE + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK = XCODE + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

if os.path.exists(TOOLCHAIN) and os.path.isdir(SDK):
    SWIFTC_CMD = [TOOLCHAIN, "-sdk", SDK]
else:
    SWIFTC_CMD = ["swiftc"]
