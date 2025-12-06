#!/bin/bash

# Build script for macOS Flutter app with Rust library
# This script builds the Rust library, creates/updates the framework, and builds the Flutter app

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUST_DIR="$SCRIPT_DIR/rust"
FRAMEWORK_DIR="$SCRIPT_DIR/macos/Frameworks/rust_lib.framework"
FLUTTER_BIN="/Users/mac/flutter/3.29.2/bin/flutter"
APP_BUNDLE="$SCRIPT_DIR/build/macos/Build/Products/Debug/tor_messenger_ui.app"

echo "🔨 Building Rust library..."
cd "$RUST_DIR"
cargo build

echo "📦 Updating framework..."
# Copy the dylib to the framework
cp "$RUST_DIR/target/debug/librust_lib.dylib" "$FRAMEWORK_DIR/Versions/Current/rust_lib"

echo "🔏 Signing framework..."
codesign --force --sign - "$FRAMEWORK_DIR"

echo "🧹 Cleaning Flutter build..."
cd "$SCRIPT_DIR"
rm -rf build/macos

echo "🏗️ Building Flutter app..."
$FLUTTER_BIN build macos --debug

echo "📦 Copying framework to app bundle..."
cp -R "$FRAMEWORK_DIR" "$APP_BUNDLE/Contents/Frameworks/"

echo "🔏 Re-signing app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "✅ Build complete!"
echo ""
echo "To run the app:"
echo "  $FLUTTER_BIN run -d macos"
echo ""
echo "Or open directly:"
echo "  open $APP_BUNDLE"
