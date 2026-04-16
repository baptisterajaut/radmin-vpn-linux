#!/bin/sh

# You might need to restart your pc if sharun doesn't create `AppDir` in this directory (It should create dirs on its own)
set -eu

ARCH="$(uname -m)"
SHARUN="https://raw.githubusercontent.com/pkgforge-dev/Anylinux-AppImages/refs/heads/main/useful-tools/quick-sharun.sh"

export ADD_HOOKS="self-updater.bg.hook"
#export UPINFO="gh-releases-zsync|${GITHUB_REPOSITORY%/*}|${GITHUB_REPOSITORY#*/}|latest|*$ARCH.AppImage.zsync"
export OUTNAME=tap_bridge-anylinux-"$ARCH".AppImage
export DESKTOP=tap_bridge.desktop
export ICON=DUMMY
export OUTPATH=./dist
export DEPLOY_OPENGL=0
export DEPLOY_VULKAN=0
export DEPLOY_DOTNET=0
export MAIN_BIN=run.sh

#Remove leftovers
rm -rf AppDir dist

# ADD LIBRARIES
wget --retry-connrefused --tries=30 "$SHARUN" -O ./quick-sharun
chmod +x ./quick-sharun

# Copy exec
mkdir -p ./AppDir/bin/build
cp -v ./*.{dll,exe,sys} ./AppDir/bin/build || :

# Point to your binaries
./quick-sharun ./tap_bridge ./run.sh

# Make AppImage
./quick-sharun --make-appimage

echo "All Done!"
