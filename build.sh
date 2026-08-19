#!/bin/bash
# Builds ClaudeActivity.app from Sources/main.swift without Xcode.
# Produces the same bundle as the Xcode project: both read the metadata from
# Resources/Info.plist and the version/deployment settings from the .pbxproj,
# so there is a single source of truth.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeActivity"
APP="${APP_NAME}.app"
BIN="${APP}/Contents/MacOS/${APP_NAME}"
PLIST_SRC="Resources/Info.plist"
PBXPROJ="${APP_NAME}.xcodeproj/project.pbxproj"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Error: swiftc not found. Run this once:"
  echo "  xcode-select --install"
  exit 1
fi

if [ ! -f "$PLIST_SRC" ]; then
  echo "Error: $PLIST_SRC not found."
  exit 1
fi

# Reads a build setting out of the Xcode project, with a fallback for the case
# where the project file is missing.
setting() {
  local key="$1" fallback="$2" value=""
  if [ -f "$PBXPROJ" ]; then
    value=$(sed -n "s/^[[:space:]]*${key} = \"\{0,1\}\([^\";]*\)\"\{0,1\};.*/\1/p" "$PBXPROJ" | head -1)
  fi
  echo "${value:-$fallback}"
}

BUNDLE_ID=$(setting PRODUCT_BUNDLE_IDENTIFIER "com.claudeactivity.app")
MARKETING_VERSION=$(setting MARKETING_VERSION "1.0")
BUILD_VERSION=$(setting CURRENT_PROJECT_VERSION "1")
DEPLOYMENT_TARGET=$(setting MACOSX_DEPLOYMENT_TARGET "13.0")

echo "-> Removing the previous build"
rm -rf "$APP"

echo "-> Creating the app bundle"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

echo "-> Expanding $PLIST_SRC (version ${MARKETING_VERSION}, build ${BUILD_VERSION})"
# The plist uses Xcode build variables; substitute them the way Xcode would.
sed -e "s/\$(PRODUCT_NAME)/${APP_NAME}/g" \
    -e "s/\$(EXECUTABLE_NAME)/${APP_NAME}/g" \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${BUNDLE_ID}/g" \
    -e "s/\$(MARKETING_VERSION)/${MARKETING_VERSION}/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/${BUILD_VERSION}/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/${DEPLOYMENT_TARGET}/g" \
    "$PLIST_SRC" > "${APP}/Contents/Info.plist"

if grep -q '\$(' "${APP}/Contents/Info.plist"; then
  echo "Error: unresolved build variables left in Info.plist:"
  grep -n '\$(' "${APP}/Contents/Info.plist"
  exit 1
fi
plutil -lint "${APP}/Contents/Info.plist" >/dev/null

if [ -f Resources/AppIcon.icns ]; then
  echo "-> Copying the app icon"
  cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
else
  echo "-> No Resources/AppIcon.icns (run: swift make-icon.swift)"
fi

echo "-> Compiling"
swiftc -O -target "$(uname -m)-apple-macos${DEPLOYMENT_TARGET}" \
  Sources/main.swift -o "$BIN" \
  || swiftc -O Sources/main.swift -o "$BIN"

echo "-> Ad-hoc signing"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (signing skipped)"

echo ""
echo "Done: $(pwd)/${APP}"
echo "Start it with:  open \"$(pwd)/${APP}\""
