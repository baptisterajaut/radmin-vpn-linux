#!/usr/bin/env bash
# Builds RadminVPN-Linux-x86_64.AppImage
#
# Inputs:  build/ populated with {tap_bridge, rvpn_filter_ui,
#                                  rvpnnetmp.sys, adapter_hook.dll,
#                                  rvpn_launcher.exe, netsh.exe, netsh64.exe}
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
for f in tap_bridge rvpnnetmp.sys adapter_hook.dll rvpn_launcher.exe netsh.exe netsh64.exe drvinst.exe rvpn_dnsfix.so rvpn_reuseport.so; do
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
# Pinned by version and sha256, so a rebuild bundles the same Wine and a replaced upstream
# asset stops the build. To update, bump both from the release page (they must go together).
WINE_VERSION="11.22"
WINE_SHA256="eafe530ccdc188ffb00ee8dae962f16b29ff0602953b73b23c9ad3394286381a"
WINE_DIR="$DIST/wine-runtime"
# Records which pinned version the extracted dir holds. It lives next to the dir, not in it,
# because everything in the dir is copied into the AppImage. A dir without a matching
# marker (for instance one left by an older version of this script) is fetched again.
WINE_MARKER="$DIST/wine-runtime.version"
if [ ! -d "$WINE_DIR" ] || [ -L "$WINE_DIR" ] || [ "$(cat "$WINE_MARKER" 2>/dev/null)" != "$WINE_VERSION" ]; then
    rm -rf "$WINE_DIR" "$WINE_MARKER" "$DIST/wine-extract-work"

    echo "[*] Downloading Wine $WINE_VERSION..."
    curl -fL -o wine.tar.xz \
        "https://github.com/Kron4ek/Wine-Builds/releases/download/$WINE_VERSION/wine-$WINE_VERSION-staging-amd64-wow64.tar.xz"
    if [ "$(sha256sum wine.tar.xz | cut -d' ' -f1)" != "$WINE_SHA256" ]; then
        echo "[-] wine.tar.xz does not match the pinned sha256 for Wine $WINE_VERSION"
        rm -f wine.tar.xz
        exit 1
    fi

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
    echo "$WINE_VERSION" > "$WINE_MARKER"
fi

# ---- Fetch appimagetool ----
# Pinned to a numbered release by sha256 (bump both together). It is checked on every run
# because the file is cached in packaging/dist.
APPIMAGETOOL_VERSION="1.9.1"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
APPIMAGETOOL="$DIST/appimagetool"
if [ ! -x "$APPIMAGETOOL" ]; then
    echo "[*] Downloading appimagetool $APPIMAGETOOL_VERSION..."
    curl -fL -o "$APPIMAGETOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-x86_64.AppImage"
    chmod +x "$APPIMAGETOOL"
fi
if [ "$(sha256sum "$APPIMAGETOOL" | cut -d' ' -f1)" != "$APPIMAGETOOL_SHA256" ]; then
    echo "[-] $APPIMAGETOOL does not match the pinned sha256 (delete it to re-download)"
    exit 1
fi

# ---- Fetch the AppImage runtime ----
# appimagetool otherwise downloads the runtime itself, from a release that moves, and
# the runtime is the first ~900 KB of the output. Pinned by hash: if upstream republishes
# 'continuous' the build stops here instead of silently changing.
RUNTIME="$DIST/runtime-x86_64"
RUNTIME_SHA256="617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46"
if [ ! -f "$RUNTIME" ]; then
    echo "[*] Downloading AppImage runtime..."
    curl -fL -o "$RUNTIME" \
        "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64"
fi
if [ "$(sha256sum "$RUNTIME" | cut -d' ' -f1)" != "$RUNTIME_SHA256" ]; then
    echo "[-] $RUNTIME does not match the pinned sha256 (delete it to re-download)"
    exit 1
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
cp "$BUILD/netsh64.exe"        "$APPDIR/usr/lib/radmin-vpn/"
cp "$BUILD/drvinst.exe"        "$APPDIR/usr/lib/radmin-vpn/"
cp "$BUILD/rvpn_dnsfix.so"     "$APPDIR/usr/lib/radmin-vpn/"
cp "$BUILD/rvpn_reuseport.so"  "$APPDIR/usr/lib/radmin-vpn/"
chmod +x "$APPDIR/usr/lib/radmin-vpn/tap_bridge"

# rvpn_filter_ui is optional (GTK4 Linux binary) — bundle if present
if [ -f "$BUILD/rvpn_filter_ui" ]; then
    cp "$BUILD/rvpn_filter_ui" "$APPDIR/usr/lib/radmin-vpn/"
    chmod +x "$APPDIR/usr/lib/radmin-vpn/rvpn_filter_ui"
    echo "[*] Bundled rvpn_filter_ui"
else
    echo "[!] rvpn_filter_ui not found in build/ — skipping (--no-ui will be implied)"
fi

# Radmin VPN Windows installer is intentionally NOT bundled — it is downloaded
# at runtime from the version pinned in lib.sh (RADMIN_VERSION), overridable via
# RADMIN_INSTALLER_URL. Never ship the proprietary installer inside the AppImage.

# run.sh (adapted, lives in the AppImage; sourced via AppRun)
cp "$ROOT/run.sh" "$APPDIR/usr/bin/run.sh"
chmod +x "$APPDIR/usr/bin/run.sh"

# lib.sh — run.sh does `source "$DIR/lib.sh"` (with set -u), so it must sit
# right next to run.sh in the AppDir or the launcher dies on line 12.
cp "$ROOT/lib.sh" "$APPDIR/usr/bin/lib.sh"

# patch_qwindows_font.py — run.sh's --fix-chat looks for it next to itself
# ($DIR/patch_qwindows_font.py). Without this it silently no-ops in the AppImage.
cp "$ROOT/patch_qwindows_font.py" "$APPDIR/usr/bin/patch_qwindows_font.py"

# AppRun
cp "$PACK/AppRun" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"

# .desktop
cp "$PACK/radmin-vpn.desktop" "$APPDIR/radmin-vpn.desktop"
cp "$PACK/radmin-vpn.desktop" "$APPDIR/usr/share/applications/"

# Icon: rasterize SVG → PNG. exclude-chunk drops the date text chunks, which would
# otherwise put the build time (and the SVG's mtime) into the PNG.
convert -background none -resize 256x256 -define png:exclude-chunk=date,time "$PACK/radmin-vpn.svg" "$APPDIR/radmin-vpn.png"
cp "$APPDIR/radmin-vpn.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/"
cp "$APPDIR/radmin-vpn.png" "$APPDIR/.DirIcon"

# Fixed mtimes for everything we added. squashfs stores every file and directory time,
# so build-time mtimes change the AppImage hash. Wine keeps the times from its tarball.
find "$APPDIR" -not -path "$APPDIR/wine/*" -exec touch -h -d @0 {} +

# ---- Package ----
echo "[*] Running appimagetool..."
rm -f "$OUT"
ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run --no-appstream \
    --runtime-file "$RUNTIME" "$APPDIR" "$OUT"

echo "[+] Built: $OUT"
ls -lh "$OUT"
