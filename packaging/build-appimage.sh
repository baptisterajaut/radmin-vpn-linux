#!/bin/bash
# Builds RadminVPN-Linux-x86_64.AppImage
#
# Inputs:  build/ populated with {tap_bridge, rvpnnetmp.sys, adapter_hook.dll,
#                                  rvpn_launcher.exe, netsh.exe}
# Output:  packaging/dist/RadminVPN-Linux-x86_64.AppImage
#
# Deps:    curl, ImageMagick (convert), appimagetool (auto-downloaded)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACK="$ROOT/packaging"
DIST="$PACK/dist"
# Named 'radmin.AppDir' not 'AppDir' because uruntime extracts wine to ./AppDir
# and we'd collide if we used the same name.
APPDIR="$DIST/radmin.AppDir"
BUILD="$ROOT/build"
OUT="$DIST/RadminVPN-Linux-x86_64.AppImage"

echo "[*] radmin-vpn-linux AppImage build"

# ---- Preflight ----
for f in tap_bridge rvpnnetmp.sys adapter_hook.dll rvpn_launcher.exe netsh.exe; do
    [ -f "$BUILD/$f" ] || { echo "[-] Missing $BUILD/$f (run 'make' first)"; exit 1; }
done
command -v curl    >/dev/null || { echo "[-] curl required"; exit 1; }
command -v convert >/dev/null || { echo "[-] ImageMagick 'convert' required (apt install imagemagick)"; exit 1; }

mkdir -p "$DIST"
cd "$DIST"

# ---- Fetch Kron4ek wine-staging-amd64-wow64 tarball ----
# Why Kron4ek: plain wine binaries, no path patching, no runtime hooks. wow64 variant runs
# 32-bit PEs inside a 64-bit process (no need for host lib32). Matches the staging build
# used for development, proven to work with Radmin's multi-process spawn pattern.
WINE_DIR="$DIST/wine-runtime"
if [ ! -d "$WINE_DIR" ] || [ -L "$WINE_DIR" ]; then
    rm -rf "$WINE_DIR" "$DIST/wine-extract-work"

    echo "[*] Resolving latest Kron4ek/Wine-Builds staging-amd64-wow64..."
    WINE_URL=$(curl -fsSL https://api.github.com/repos/Kron4ek/Wine-Builds/releases/latest \
        | grep -oE '"browser_download_url": *"[^"]*staging-amd64-wow64\.tar\.xz"' \
        | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
    [ -n "$WINE_URL" ] || { echo "[-] Could not resolve Kron4ek wine URL"; exit 1; }
    echo "[*] Downloading $WINE_URL"
    curl -fL -o wine.tar.xz "$WINE_URL"

    echo "[*] Extracting wine tarball..."
    WORK="$DIST/wine-extract-work"
    mkdir -p "$WORK"
    tar -xJf wine.tar.xz -C "$WORK"
    rm -f wine.tar.xz

    # Kron4ek tarballs create a single top-level dir (e.g. wine-staging-amd64-wow64)
    EXTRACTED=$(find "$WORK" -maxdepth 1 -mindepth 1 -type d | head -1)
    if [ -z "$EXTRACTED" ] || [ ! -x "$EXTRACTED/bin/wine" ]; then
        echo "[-] Unexpected Kron4ek extraction layout (no bin/wine):"
        ls -la "$WORK"
        exit 1
    fi
    mv "$EXTRACTED" "$WINE_DIR"
    rm -rf "$WORK"
fi

# ---- Fetch appimagetool ----
APPIMAGETOOL="$DIST/appimagetool"
if [ ! -x "$APPIMAGETOOL" ]; then
    echo "[*] Downloading appimagetool..."
    curl -fL -o "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi

# ---- Assemble AppDir ----
echo "[*] Assembling AppDir..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/lib/radmin-vpn" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# Bundled wine (cp -a preserves internal symlinks for lib versioning)
mkdir -p "$APPDIR/wine"
cp -a "$WINE_DIR/." "$APPDIR/wine/"

# Our Linux binary + PE files (all go to one dir)
cp "$BUILD/tap_bridge"         "$APPDIR/usr/lib/radmin-vpn/"
cp "$BUILD/rvpnnetmp.sys"      "$APPDIR/usr/lib/radmin-vpn/"
cp "$BUILD/adapter_hook.dll"   "$APPDIR/usr/lib/radmin-vpn/"
cp "$BUILD/rvpn_launcher.exe"  "$APPDIR/usr/lib/radmin-vpn/"
cp "$BUILD/netsh.exe"          "$APPDIR/usr/lib/radmin-vpn/"
chmod +x "$APPDIR/usr/lib/radmin-vpn/tap_bridge"

# run.sh (adapted, lives in the AppImage; sourced via AppRun)
cp "$ROOT/run.sh" "$APPDIR/usr/bin/run.sh"
chmod +x "$APPDIR/usr/bin/run.sh"

# AppRun
cp "$PACK/AppRun" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"

# .desktop
cp "$PACK/radmin-vpn.desktop" "$APPDIR/radmin-vpn.desktop"
cp "$PACK/radmin-vpn.desktop" "$APPDIR/usr/share/applications/"

# Icon: rasterize SVG → PNG
convert -background none -resize 256x256 "$PACK/radmin-vpn.svg" "$APPDIR/radmin-vpn.png"
cp "$APPDIR/radmin-vpn.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
cp "$APPDIR/radmin-vpn.png" "$APPDIR/.DirIcon"

# ---- Package ----
echo "[*] Running appimagetool..."
rm -f "$OUT"
ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUT"

echo "[+] Built: $OUT"
ls -lh "$OUT"
