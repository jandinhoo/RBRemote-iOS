#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENCODED_DIR="$ROOT_DIR/EncodedAssets"

decode_asset() {
  local source_file="$ENCODED_DIR/$1"
  local destination_file="$ROOT_DIR/$2"
  mkdir -p "$(dirname "$destination_file")"
  base64 --decode < "$source_file" > "$destination_file"
}

decode_asset "rb_remote_logo.png.base64" "RBRemote/Assets.xcassets/Logo.imageset/rb_remote_logo.png"
decode_asset "tutorial_api.png.base64" "RBRemote/Assets.xcassets/TutorialApi.imageset/tutorial_api.png"
decode_asset "tutorial_ipconfig.png.base64" "RBRemote/Assets.xcassets/TutorialIpconfig.imageset/tutorial_ipconfig.png"
decode_asset "tutorial_discord.png.base64" "RBRemote/Assets.xcassets/TutorialDiscord.imageset/tutorial_discord.png"
decode_asset "Icon-20@2x.png.base64" "RBRemote/Assets.xcassets/AppIcon.appiconset/Icon-20@2x.png"
decode_asset "Icon-20@3x.png.base64" "RBRemote/Assets.xcassets/AppIcon.appiconset/Icon-20@3x.png"
decode_asset "Icon-29@2x.png.base64" "RBRemote/Assets.xcassets/AppIcon.appiconset/Icon-29@2x.png"
decode_asset "Icon-29@3x.png.base64" "RBRemote/Assets.xcassets/AppIcon.appiconset/Icon-29@3x.png"
decode_asset "Icon-40@2x.png.base64" "RBRemote/Assets.xcassets/AppIcon.appiconset/Icon-40@2x.png"
decode_asset "Icon-40@3x.png.base64" "RBRemote/Assets.xcassets/AppIcon.appiconset/Icon-40@3x.png"
decode_asset "Icon-60@2x.png.base64" "RBRemote/Assets.xcassets/AppIcon.appiconset/Icon-60@2x.png"
decode_asset "Icon-60@3x.png.base64" "RBRemote/Assets.xcassets/AppIcon.appiconset/Icon-60@3x.png"

echo "Assets restored."
