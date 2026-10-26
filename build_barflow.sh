#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_WORKSPACE_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="BarFlow"
BUNDLE_ID="com.hunglx.BarFlow"
VERSION="1.3.0"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ROOT_APP_BUNDLE="$ROOT_WORKSPACE_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
DIST_DIR="$PROJECT_DIR/dist"

echo "==> [1/6] Đang biên dịch $APP_NAME (Universal Binary arm64 + x86_64 Release)..."
if swift build -c release --product "$APP_NAME" --arch arm64 --arch x86_64 2>/dev/null; then
    BIN_PATH="$(swift build -c release --product "$APP_NAME" --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
else
    swift build -c release --product "$APP_NAME"
    BIN_PATH="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
fi

echo "==> [2/6] Đang tạo biểu tượng ứng dụng (AppIcon.icns)..."
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

swift - "$ICONSET_DIR" << 'SWIFT_ICON'
import AppKit

let outDir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, name) in sizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
    let inset = CGFloat(px) * 0.08
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let radius = bgRect.width * 0.225

    let path = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.92, alpha: 1.0),
        NSColor(calibratedRed: 0.05, green: 0.65, blue: 0.95, alpha: 1.0)
    ])!
    gradient.draw(in: path, angle: -45)

    if let symbol = NSImage(systemSymbolName: "menubar.arrow.down.rectangle", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.44, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let configured = symbol.withSymbolConfiguration(config) {
            let symSize = configured.size
            let drawRect = NSRect(
                x: (CGFloat(px) - symSize.width) / 2.0,
                y: (CGFloat(px) - symSize.height) / 2.0,
                width: symSize.width,
                height: symSize.height
            )
            configured.draw(in: drawRect)
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
SWIFT_ICON

echo "==> [3/6] Đang đóng gói $APP_NAME.app..."
STAGE_ROOT="$(mktemp -d /tmp/BarFlowBuildStage.XXXXXX)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE_APP="$STAGE_ROOT/$APP_NAME.app"
STAGE_CONTENTS="$STAGE_APP/Contents"
STAGE_MACOS="$STAGE_CONTENTS/MacOS"
STAGE_RESOURCES="$STAGE_CONTENTS/Resources"
mkdir -p "$STAGE_MACOS" "$STAGE_RESOURCES"

cp -X "$BIN_PATH" "$STAGE_MACOS/$APP_NAME"
chmod +x "$STAGE_MACOS/$APP_NAME"

iconutil -c icns "$ICONSET_DIR" -o "$STAGE_RESOURCES/AppIcon.icns" || true

cat > "$STAGE_CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>vi</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>BarFlow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>4</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> [4/6] Đang ký số (Ad-hoc Codesign)..."
xattr -cr "$STAGE_APP" 2>/dev/null || true
codesign --force --deep --sign - "$STAGE_APP"
codesign --verify --deep --strict "$STAGE_APP"

rm -rf "$APP_BUNDLE"
ditto --noextattr "$STAGE_APP" "$APP_BUNDLE"

echo "==> [5/6] Đang tạo bộ cài đặt .DMG và .ZIP tại thư mục dist/..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

DMG_STAGING="$STAGE_ROOT/dmg_staging"
mkdir -p "$DMG_STAGING"

ditto --noextattr "$STAGE_APP" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

cat > "$DMG_STAGING/Cai_Dat_BarFlow.command" << 'INSTALLER_EOF'
#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$DIR/BarFlow.app"
APP_DST="/Applications/BarFlow.app"

echo "===================================================="
echo "  Đang cài đặt BarFlow vào /Applications..."
echo "===================================================="

pkill -f BarFlow 2>/dev/null || true
rm -rf "$APP_DST"
ditto --noextattr "$APP_SRC" "$APP_DST"

# Gỡ cờ cách ly Gatekeeper (Quarantine) và làm mới quyền Accessibility khi nâng cấp phiên bản
xattr -cr "$APP_DST" 2>/dev/null || true
tccutil reset Accessibility com.hunglx.BarFlow 2>/dev/null || true

echo "✓ Đã cài đặt thành công tại: $APP_DST"
echo "✓ Đang khởi chạy BarFlow..."
open "$APP_DST"
echo ""
echo "Lưu ý: Trong lần chạy đầu tiên, hãy cấp quyền Accessibility (Trợ năng) trong System Settings -> Privacy & Security -> Accessibility để BarFlow quản lý các biểu tượng trên Menu Bar."
sleep 2
INSTALLER_EOF
chmod +x "$DMG_STAGING/Cai_Dat_BarFlow.command"
xattr -cr "$DMG_STAGING" 2>/dev/null || true

DMG_PATH="$DIST_DIR/${APP_NAME}-Installer-v${VERSION}.dmg"
hdiutil create -volname "${APP_NAME} Installer" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

ZIP_PATH="$DIST_DIR/${APP_NAME}-v${VERSION}-macOS.zip"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE_APP" "$ZIP_PATH"

echo "==> [6/6] Đồng bộ $ROOT_APP_BUNDLE..."
if [ "$ROOT_WORKSPACE_DIR" != "$PROJECT_DIR" ] && [ -d "$ROOT_WORKSPACE_DIR/BarFlow.app" -o -d "$ROOT_WORKSPACE_DIR/Sources" ]; then
    rm -rf "$ROOT_APP_BUNDLE"
    ditto --noextattr "$STAGE_APP" "$ROOT_APP_BUNDLE"
fi

echo "==> Hoàn tất!"
echo "    - Ứng dụng: $APP_BUNDLE"
echo "    - Bộ cài DMG: $DMG_PATH"
echo "    - Bản nén ZIP: $ZIP_PATH"
