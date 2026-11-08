#!/bin/sh
# Copies core/dist/darwin-<arch>/zjuconnect-core into the app bundle's
# Resources. Called from the Runner target's "Run Script" build phase.
# Builds a universal binary when both arches exist.
set -e
DIST="$PROJECT_DIR/../core/dist"
DEST="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Resources"
mkdir -p "$DEST"
A="$DIST/darwin-arm64/zjuconnect-core"
X="$DIST/darwin-amd64/zjuconnect-core"
if [ -f "$A" ] && [ -f "$X" ]; then
  lipo -create "$A" "$X" -output "$DEST/zjuconnect-core"
elif [ -f "$A" ]; then
  cp "$A" "$DEST/zjuconnect-core"
elif [ -f "$X" ]; then
  cp "$X" "$DEST/zjuconnect-core"
else
  echo "warning: zjuconnect-core not built (run core/build.sh darwin-arm64 darwin-amd64)"
  exit 0
fi
chmod +x "$DEST/zjuconnect-core"
