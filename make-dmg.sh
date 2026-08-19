#!/bin/bash
# Packages ClaudeActivity.app into a distributable disk image.
#
#   ./build.sh && ./make-dmg.sh
#
# The result lands in build/ClaudeActivity-<version>.dmg and holds the app, a
# symlink to /Applications, and a short text file explaining how to get past
# Gatekeeper.
#
# The app is signed ad hoc, not with a Developer ID, and is not notarized. That
# is a deliberate choice: notarization needs a paid Apple Developer Program
# membership. The cost is that macOS blocks the app on first launch and the user
# has to allow it once — see "How to open ClaudeActivity.txt" below, which ships
# inside the image so the instructions are there exactly when they are needed.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeActivity"
APP="${APP_NAME}.app"
STAGE="build/dmg"

if [ ! -d "$APP" ]; then
  echo "Error: $APP not found. Build it first:"
  echo "  ./build.sh"
  exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "${APP}/Contents/Info.plist")
DMG="build/${APP_NAME}-${VERSION}.dmg"

echo "-> Staging ${APP} (version ${VERSION})"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
# ditto rather than cp: it keeps the code signature and resource forks intact.
ditto "$APP" "${STAGE}/${APP}"
ln -s /Applications "${STAGE}/Applications"

cat > "${STAGE}/How to open ${APP_NAME}.txt" <<INSTRUCTIONS
${APP_NAME} ${VERSION}
https://github.com/Promotos/ClaudeActivity

${APP_NAME} is signed, but not with a paid Apple Developer ID, so macOS asks for
your consent once before it will run it. Four steps:

1. Drag ${APP_NAME} onto the Applications folder in this window.

   Do this before starting it. An app launched straight from this disk image or
   from your Downloads folder runs from a temporary path that disappears again,
   which also breaks the "Start at Login" option.

2. Open ${APP_NAME} from your Applications folder. macOS says it "could not
   verify" the app. Click "Done" — not "Move to Trash".

3. Open System Settings > Privacy & Security and scroll all the way down. There
   is a line about ${APP_NAME} with an "Open Anyway" button. Click it and
   confirm with Touch ID or your password.

   No such line? macOS only offers it for a while after a blocked launch. Open
   the app again, then look right away.

4. An icon appears in the menu bar. That is the whole app — it has no window and
   no Dock icon. Click the icon for status and settings.

macOS remembers the exception from then on. It is tied to the signature rather
than the location, so a later update brings the prompt back once.
INSTRUCTIONS

echo "-> Creating the disk image"
# ULFO = LZFSE compressed, read-only. Smaller and faster than the older UDZO.
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format ULFO -quiet "$DMG"

rm -rf "$STAGE"

echo "-> Verifying"
hdiutil verify -quiet "$DMG"
codesign --verify --strict "$APP" \
  && echo "   app signature: ok (ad hoc)" \
  || echo "   app signature: INVALID"

echo ""
echo "Done: $(pwd)/${DMG}  ($(du -h "$DMG" | cut -f1))"
echo ""
echo "Not notarized: whoever downloads this has to allow the app once under"
echo "System Settings > Privacy & Security. The image carries the instructions."
