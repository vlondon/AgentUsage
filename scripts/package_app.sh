#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
APP_DIR="$PROJECT_DIR/build/AgentAllowance.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICON_SOURCE="$PROJECT_DIR/Packaging/AppIcon.icns"

cd "$PROJECT_DIR"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

# Start from an empty bundle so resources from earlier builds never linger.
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp "$BIN_DIR/AgentAllowance" "$CONTENTS_DIR/MacOS/AgentAllowance"
cp "$PROJECT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"

if [[ -f "$ICON_SOURCE" ]]; then
    cp "$ICON_SOURCE" "$CONTENTS_DIR/Resources/AppIcon.icns"

    # With full Xcode installed, also compile the icon into an asset catalog, the format
    # macOS 26 prefers for app icons. Command Line Tools alone have no actool, so the
    # bundle then keeps only the .icns (CFBundleIconFile).
    if ACTOOL=$(xcrun --find actool 2>/dev/null); then
        ASSET_WORK=$(mktemp -d)
        trap 'rm -rf "$ASSET_WORK"' EXIT
        ICONSET_DIR="$ASSET_WORK/Assets.xcassets/AppIcon.appiconset"
        mkdir -p "$ICONSET_DIR" "$ASSET_WORK/out"

        iconutil -c iconset -o "$ASSET_WORK/AppIcon.iconset" "$ICON_SOURCE"
        cp "$ASSET_WORK/AppIcon.iconset/"*.png "$ICONSET_DIR/"

        echo '{"info":{"author":"xcode","version":1}}' > "$ASSET_WORK/Assets.xcassets/Contents.json"
        IMAGES=()
        for size in 16 32 128 256 512; do
            IMAGES+=("{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"1x\",\"filename\":\"icon_${size}x${size}.png\"}")
            IMAGES+=("{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"2x\",\"filename\":\"icon_${size}x${size}@2x.png\"}")
        done
        echo "{\"images\":[${(j:,:)IMAGES}],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "$ICONSET_DIR/Contents.json"

        "$ACTOOL" "$ASSET_WORK/Assets.xcassets" \
            --compile "$ASSET_WORK/out" \
            --platform macosx \
            --minimum-deployment-target "$(plutil -extract LSMinimumSystemVersion raw "$CONTENTS_DIR/Info.plist")" \
            --app-icon AppIcon \
            --output-partial-info-plist "$ASSET_WORK/partial.plist" > /dev/null
        cp "$ASSET_WORK/out/Assets.car" "$CONTENTS_DIR/Resources/Assets.car"
        plutil -replace CFBundleIconName -string AppIcon "$CONTENTS_DIR/Info.plist"
    fi
fi

# Sign with a stable identity when one is available, so macOS keeps "Always Allow" for
# the app's Keychain items across rebuilds; an ad-hoc signature changes with every build.
# Order: SIGN_IDENTITY, a valid Apple Development certificate, the self-signed identity
# from scripts/create_signing_identity.sh, then ad-hoc.
LOCAL_IDENTITY="Agent Allowance Local Signing"
SIGN_IDENTITY=${SIGN_IDENTITY:-}
SIGN_LABEL=$SIGN_IDENTITY
if [[ -z "$SIGN_IDENTITY" ]]; then
    VALID_IDENTITIES=$(security find-identity -v -p codesigning 2> /dev/null || true)
    ALL_IDENTITIES=$(security find-identity -p codesigning 2> /dev/null || true)
    if MATCH=$(print -r -- "$VALID_IDENTITIES" | grep -m 1 -E '^ *[0-9]+\) [0-9A-F]{40} "Apple Development: '); then
        :
    elif MATCH=$(print -r -- "$ALL_IDENTITIES" | grep -m 1 -F "\"$LOCAL_IDENTITY\""); then
        :
    else
        MATCH=""
    fi
    if [[ -n "$MATCH" ]]; then
        # Sign by SHA-1 so an older certificate with the same name cannot be picked instead.
        SIGN_IDENTITY=$(print -r -- "$MATCH" | sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}) .*/\1/')
        SIGN_LABEL=$(print -r -- "$MATCH" | sed -E 's/^[^"]*"([^"]*)".*/\1/')
    fi
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "Signing with: $SIGN_LABEL"
    codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "Signing ad-hoc (no signing identity found; see README, Code signing)"
    codesign --force --deep --sign - "$APP_DIR"
fi
echo "$APP_DIR"
