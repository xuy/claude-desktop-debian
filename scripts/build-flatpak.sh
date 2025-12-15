#!/bin/bash
set -euo pipefail

VERSION="$1"
ARCHITECTURE="$2"
WORK_DIR="$3"
APP_STAGING_DIR="$4"
PACKAGE_NAME="$5"

FLATPAK_APP_ID="com.anthropic.ClaudeDesktop"
BUILD_DIR="$WORK_DIR/flatpak-build"
CONTEXT_DIR="$WORK_DIR/flatpak-context"
REPO_DIR="$WORK_DIR/flatpak-repo"
MANIFEST_PATH="$WORK_DIR/claude-desktop-flatpak.yml"
BUNDLE_PATH="$WORK_DIR/${PACKAGE_NAME}-${VERSION}-${ARCHITECTURE}.flatpak"

if [ "$ARCHITECTURE" = "amd64" ]; then
    FLATPAK_ARCH="x86_64"
elif [ "$ARCHITECTURE" = "arm64" ]; then
    FLATPAK_ARCH="aarch64"
else
    echo "❌ Unsupported architecture for Flatpak: $ARCHITECTURE"
    exit 1
fi

echo "--- Starting Flatpak Build ---"
echo "App ID: $FLATPAK_APP_ID"
echo "Version: $VERSION"
echo "Architecture: $ARCHITECTURE (Flatpak: $FLATPAK_ARCH)"

echo "Preparing Flatpak build context..."
rm -rf "$BUILD_DIR" "$CONTEXT_DIR" "$REPO_DIR"
mkdir -p "$BUILD_DIR" "$CONTEXT_DIR/app" "$CONTEXT_DIR/icons"

# Copy staged Electron application into the context
rsync -a "$APP_STAGING_DIR"/ "$CONTEXT_DIR/app/"

# Prepare icons
ICON_256_SRC="$WORK_DIR/claude_6_256x256x32.png"
ICON_64_SRC="$WORK_DIR/claude_7_64x64x32.png"
if [ -f "$ICON_256_SRC" ]; then
    install -Dm644 "$ICON_256_SRC" "$CONTEXT_DIR/icons/claude-desktop-256.png"
else
    echo "⚠️  256x256 icon not found at $ICON_256_SRC"
fi
if [ -f "$ICON_64_SRC" ]; then
    install -Dm644 "$ICON_64_SRC" "$CONTEXT_DIR/icons/claude-desktop-64.png"
elif [ -f "$ICON_256_SRC" ] && command -v convert >/dev/null 2>&1; then
    echo "Scaling 256px icon down to 64px for Flatpak..."
    convert "$ICON_256_SRC" -resize 64x64 "$CONTEXT_DIR/icons/claude-desktop-64.png"
fi

# Launcher
cat > "$CONTEXT_DIR/claude-desktop.sh" << 'LAUNCHER'
#!/bin/bash
set -euo pipefail

LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-desktop-flatpak"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/launcher.log"
echo "--- Claude Desktop Flatpak Launcher ---" > "$LOG_FILE"
echo "Timestamp: $(date)" >> "$LOG_FILE"
echo "Args: $@" >> "$LOG_FILE"

APP_DIR="/app/lib/claude-desktop"
ELECTRON_EXEC="$APP_DIR/node_modules/electron/dist/electron"
APP_PATH="$APP_DIR/node_modules/electron/dist/resources/app.asar"

export ELECTRON_FORCE_IS_PACKAGED=true
export ELECTRON_USE_SYSTEM_TITLE_BAR=1

IS_WAYLAND=false
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  IS_WAYLAND=true
fi

ELECTRON_ARGS=("$APP_PATH" "--disable-features=CustomTitlebar" "--no-sandbox")

if [ "$IS_WAYLAND" = true ]; then
  ELECTRON_ARGS+=("--ozone-platform=wayland")
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform,WaylandWindowDecorations,GlobalShortcutsPortal")
  ELECTRON_ARGS+=("--enable-wayland-ime")
  ELECTRON_ARGS+=("--wayland-text-input-version=3")
else
  ELECTRON_ARGS+=("--enable-features=UseOzonePlatform")
fi

cd "$APP_DIR"
exec "$ELECTRON_EXEC" "${ELECTRON_ARGS[@]}" "$@"
LAUNCHER
chmod +x "$CONTEXT_DIR/claude-desktop.sh"

# Desktop entry
cat > "$CONTEXT_DIR/claude-desktop.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Claude
Comment=Claude Desktop for Linux
Exec=claude-desktop %u
Icon=$FLATPAK_APP_ID
Categories=Office;Utility;Network;
Terminal=false
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
X-Flatpak=$FLATPAK_APP_ID
EOF

# Manifest
cat > "$MANIFEST_PATH" << EOF
app-id: $FLATPAK_APP_ID
runtime: org.freedesktop.Platform
runtime-version: "23.08"
sdk: org.freedesktop.Sdk
command: claude-desktop
finish-args:
  - --share=network
  - --socket=fallback-x11
  - --socket=wayland
  - --device=dri
  - --filesystem=home
  - --talk-name=org.freedesktop.portal.Desktop
  - --talk-name=org.freedesktop.portal.FileChooser
  - --talk-name=org.freedesktop.Notifications
modules:
  - name: claude-desktop
    buildsystem: simple
    build-commands:
      - install -Dm755 claude-desktop.sh /app/bin/claude-desktop
      - install -Dm644 claude-desktop.desktop /app/share/applications/$FLATPAK_APP_ID.desktop
      - if [ -f icons/claude-desktop-256.png ]; then install -Dm644 icons/claude-desktop-256.png /app/share/icons/hicolor/256x256/apps/$FLATPAK_APP_ID.png; fi
      - if [ -f icons/claude-desktop-64.png ]; then install -Dm644 icons/claude-desktop-64.png /app/share/icons/hicolor/64x64/apps/$FLATPAK_APP_ID.png; fi
      - mkdir -p /app/lib/claude-desktop
      - cp -r app/* /app/lib/claude-desktop/
      - mkdir -p /app/lib/claude-desktop/node_modules/electron/dist/resources
      - mv /app/lib/claude-desktop/app.asar /app/lib/claude-desktop/node_modules/electron/dist/resources/
      - mv /app/lib/claude-desktop/app.asar.unpacked /app/lib/claude-desktop/node_modules/electron/dist/resources/
    sources:
      - type: dir
        path: $CONTEXT_DIR
EOF

echo "Building Flatpak bundle..."
flatpak-builder --force-clean --default-branch=stable --repo="$REPO_DIR" "$BUILD_DIR" "$MANIFEST_PATH"
flatpak build-bundle "$REPO_DIR" "$BUNDLE_PATH" "$FLATPAK_APP_ID" stable --arch="$FLATPAK_ARCH"

echo "✓ Flatpak bundle created at $BUNDLE_PATH"

exit 0
