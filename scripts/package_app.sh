#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR="$PROJECT_DIR/build/AgentAllowance.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/AgentAllowance" "$CONTENTS_DIR/MacOS/AgentAllowance"
cp "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"

if [[ -f "$PROJECT_DIR/Packaging/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Packaging/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi

if [[ -f "$PROJECT_DIR/Packaging/push-icon.png" ]]; then
    cp "$PROJECT_DIR/Packaging/push-icon.png" "$CONTENTS_DIR/Resources/push-icon.png"
fi

if [[ -f "$PROJECT_DIR/Packaging/simple-gauge.png" ]]; then
    cp "$PROJECT_DIR/Packaging/simple-gauge.png" "$CONTENTS_DIR/Resources/simple-gauge.png"
fi

codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
