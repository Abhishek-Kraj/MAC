#!/bin/bash
set -e

# Usage: ./build.sh [--channel dev|beta|prod] [--run]
#
# Each channel gets its own bundle ID, app name, executable and data folder,
# so Dev, Beta and Production builds can be installed side by side without
# sharing settings, sessions or privacy permissions. Dev is the default for
# local work; releases are built with --channel beta or --channel prod.
CHANNEL="dev"
RUN=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel|-c) CHANNEL="$2"; shift 2 ;;
        --channel=*)  CHANNEL="${1#*=}"; shift ;;
        --run|-r)     RUN=1; shift ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: ./build.sh [--channel dev|beta|prod] [--run]" >&2
            exit 1 ;;
    esac
done

case "$CHANNEL" in
    dev)  BUNDLE_ID="tech.thecloser.mac.dev";  APP_NAME="TheCloser Dev";  EXEC_NAME="thecloser-dev" ;;
    beta) BUNDLE_ID="tech.thecloser.mac.beta"; APP_NAME="TheCloser Beta"; EXEC_NAME="thecloser-beta" ;;
    prod) BUNDLE_ID="tech.thecloser.mac";      APP_NAME="TheCloser";      EXEC_NAME="thecloser" ;;
    *)
        echo "Unknown channel: $CHANNEL (expected dev, beta or prod)" >&2
        exit 1 ;;
esac

echo "🔨 Building $APP_NAME ($CHANNEL)..."

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$PROJECT_DIR/MacOverlay"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# Only create the bundle structure if it doesn't exist yet.
# Avoid rm -rf so macOS keeps the app's TCC (privacy permission) record across builds.
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "📦 Compiling Swift sources..."
SWIFT_SOURCES=()
while IFS= read -r -d '' f; do SWIFT_SOURCES+=("$f"); done < <(find "$SRC_DIR" -type f -name "*.swift" -print0)

swiftc \
    -O \
    -o "$MACOS_DIR/$EXEC_NAME" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework Speech \
    -framework ScreenCaptureKit \
    -framework EventKit \
    -framework UserNotifications \
    -framework WebKit \
    -framework PDFKit \
    -framework UniformTypeIdentifiers \
    -framework Network \
    -framework CryptoKit \
    -target arm64-apple-macos14.0 \
    "${SWIFT_SOURCES[@]}"

PLIST="$CONTENTS_DIR/Info.plist"
cp "$SRC_DIR/Info.plist" "$PLIST"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleName $APP_NAME" \
    -c "Set :CFBundleDisplayName $APP_NAME" \
    -c "Set :CFBundleExecutable $EXEC_NAME" \
    -c "Add :TCChannel string $CHANNEL" \
    "$PLIST"

# Sign the bundle. We attach the entitlements file so the
# `com.apple.developer.applesignin` capability is encoded into the bundle
# signature — required for the SignInWithAppleButton to even render.
#
# Signing identity for local builds matters for MORE than Gatekeeper:
# macOS TCC (Screen Recording, Microphone) keys its grants to the binary.
# An ad-hoc signed app changes identity on every rebuild, so every grant
# made in System Settings silently stops applying the next time the app
# is rebuilt — the toggle stays green while capture is refused. A stable
# identity (a self-signed "TheCloser Dev Signing" cert, or a Developer ID)
# keeps the grant across builds. Dev channel preferences, in order:
# CODESIGN_IDENTITY env var → the local dev cert when present → ad-hoc.
#
# Developer ID Application is what ships to real customers: it's
# provisioned for the `tech.thecloser.mac` bundle ID with the Sign in
# with Apple capability enabled in Apple Developer's Identifiers panel.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" && "$CHANNEL" == "dev" ]] \
   && security find-identity -v -p codesigning 2>/dev/null | grep -q "TheCloser Dev Signing"; then
    SIGN_IDENTITY="TheCloser Dev Signing"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # Ad-hoc: fine for local builds. No Hardened Runtime: with an ad-hoc
    # signature it can stop the app launching (launchd POSIX 163).
    echo "🔏 Signing ad-hoc (set CODESIGN_IDENTITY to sign for release)..."
    codesign -f -s - \
        --entitlements "$SRC_DIR/MacOverlay.entitlements" \
        "$APP_DIR" 2>/dev/null || true
elif [[ "$SIGN_IDENTITY" == "TheCloser Dev Signing" ]]; then
    # Local dev cert: a stable identity so TCC grants survive rebuilds.
    # No Hardened Runtime or timestamp — those are release concerns, and
    # both add failure modes (launchd, network) a dev loop must not have.
    echo "🔏 Signing with the local dev identity (stable across rebuilds)..."
    codesign -f -s "$SIGN_IDENTITY" \
        --entitlements "$SRC_DIR/MacOverlay.entitlements" \
        "$APP_DIR"
    codesign --verify --strict "$APP_DIR"
else
    # Developer ID: Hardened Runtime and a secure timestamp, which Apple
    # requires to notarize. Release.entitlements lets the Hardened Runtime
    # allow the microphone. package.sh notarizes the DMG afterwards.
    echo "🔏 Signing with $SIGN_IDENTITY (Hardened Runtime)..."
    codesign -f -s "$SIGN_IDENTITY" \
        --options runtime --timestamp \
        --entitlements "$SRC_DIR/Release.entitlements" \
        "$APP_DIR"
    codesign --verify --strict --verbose=2 "$APP_DIR"
fi

echo ""
echo "✅ Build complete!"
echo "📍 App location: $APP_DIR"

if [[ $RUN -eq 1 ]]; then
    echo "🔄 Relaunching..."
    pkill -x "$EXEC_NAME" 2>/dev/null; sleep 0.3
    open "$APP_DIR"
    echo "✅ Running!"
else
    echo ""
    echo "To run:          open \"$APP_DIR\""
    echo "To rebuild+run:  ./build.sh --channel $CHANNEL --run"
fi
