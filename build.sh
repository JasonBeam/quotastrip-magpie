#!/bin/bash
# Build QuotaStrip.app as a universal binary (x86_64 + arm64).
# Covers both Intel Touch Bar Macs and the Apple Silicon 13" MacBook Pro (M1 2020 / M2 2022),
# which also have a Touch Bar.
#
#   ./build.sh            # build into /tmp/QuotaStrip.app
#   ./build.sh --run      # build, then (re)launch the app
set -e
cd "$(dirname "$0")"

APP=/tmp/QuotaStrip.app
CONTENTS="$APP/Contents"
# Refuse to delete an unexpected target or follow a substituted bundle symlink.
[ "$APP" = /tmp/QuotaStrip.app ] && [ ! -L "$APP" ] || exit 1
printf 'Replacing build bundle: %s\n' "$APP"
rm -rf "${APP:?}"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp Sources/Info.plist "$CONTENTS/Info.plist"
cp Resources/deepseek-logo.png Resources/deepseek-logo-peak.png \
   Resources/deepseek-holidays-2026.json Resources/deepseek-holidays-2027.json \
   Resources/magpie-logo.png "$CONTENTS/Resources/"
cp Resources/quota.py Resources/codex-logo.png \
   Resources/codex_notify.sh Resources/AppIcon.icns "$CONTENTS/Resources/"
chmod +x "$CONTENTS/Resources/codex_notify.sh"

# Compile one slice per architecture, then merge with lipo.
# Liquid Glass (NSGlassEffectView) 要 macOS 26 SDK；CommandLineTools 自带的 SDK 太旧，
# 有 Xcode 就用 Xcode 里的 SDK，没有就退回系统默认（此时玻璃降级为 NSVisualEffectView）。
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
TC=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
if [ -d "$SDK" ] && [ -x "$TC" ]; then
    SWIFTC="$TC"            # Xcode 自带 toolchain：CommandLineTools 的 swiftc 读不了新 SDK
else
    SDK="$(xcrun --show-sdk-path)"
    SWIFTC="$(xcrun -f swiftc)"
fi

SLICES=()
for arch in x86_64 arm64; do
    out="/tmp/quotastrip-$arch"
    echo "compiling $arch ..."
    "$SWIFTC" -O -swift-version 5 -target "$arch-apple-macosx11.0" \
        -sdk "$SDK" \
        Sources/*.swift -o "$out" \
        -framework AppKit -framework ServiceManagement -framework Security \
        -F /System/Library/PrivateFrameworks -framework DFRFoundation
    SLICES+=("$out")
done

lipo -create "${SLICES[@]}" -output "$CONTENTS/MacOS/QuotaStrip"
rm -f "${SLICES[@]}"

# Prefer a stable signing identity: macOS binds a Keychain item's "Always Allow"
# grant to the signing identity, so an ad-hoc signature loses that grant on every
# rebuild and the user is asked for the login password again. Set
# QS_SIGN_IDENTITY to override, or QS_SIGN_IDENTITY="-" for a throwaway ad-hoc build.
if [ -z "${QS_SIGN_IDENTITY+x}" ]; then
    QS_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development[^"]*"' \
        | head -1 | tr -d '"')
    if [ -z "$QS_SIGN_IDENTITY" ]; then
        QS_SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -o '"Developer ID Application[^"]*"' \
            | head -1 | tr -d '"')
    fi
    [ -n "$QS_SIGN_IDENTITY" ] || QS_SIGN_IDENTITY="-"
fi
echo "signing with: $QS_SIGN_IDENTITY"
codesign --force --deep -s "$QS_SIGN_IDENTITY" "$APP"

echo "built $APP ($(lipo -archs "$CONTENTS/MacOS/QuotaStrip"))"

if [ "$1" = "--run" ]; then
    pkill -x QuotaStrip 2>/dev/null || true
    sleep 1
    open "$APP"
fi
