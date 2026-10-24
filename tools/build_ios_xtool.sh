#!/usr/bin/env bash
# Athena iOS build script using xtool (https://github.com/xtool-org/xtool)
# Cross-platform Xcode replacement for Linux, Windows (WSL), and macOS.

set -e

echo "=== Athena iOS Build with xtool ==="

# Check for xtool binary or AppImage
if ! command -v xtool &> /dev/null; then
  echo "xtool not found in PATH. Checking local tools..."
  if [ ! -f "tools/xtool-x86_64.AppImage" ]; then
    echo "Downloading latest xtool AppImage from xtool-org/xtool..."
    mkdir -p tools
    curl -L -o tools/xtool-x86_64.AppImage https://github.com/xtool-org/xtool/releases/download/1.23.0/xtool-x86_64.AppImage
    chmod +x tools/xtool-x86_64.AppImage
  fi
  XTOOL_CMD="tools/xtool-x86_64.AppImage"
else
  XTOOL_CMD="xtool"
fi

echo "Setting up xtool SDK..."
$XTOOL_CMD setup

echo "Building Athena iOS app package..."
cd app/ios
$XTOOL_CMD dev --configuration release

echo "Packaging into IPA archive..."
mkdir -p ../../releases
mkdir -p Payload
if [ -d ".build/release/Athena.app" ]; then
  cp -r .build/release/Athena.app Payload/
elif [ -d "Runner" ]; then
  cp -r Runner Payload/Athena.app
fi
zip -r ../../releases/athena-ios-release.ipa Payload
rm -rf Payload

echo "[SUCCESS] IPA built at releases/athena-ios-release.ipa"
