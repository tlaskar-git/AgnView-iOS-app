#!/bin/sh
# Check that a built AgnView.app carries its app icon, the way App Store
# Connect reads it. Fails when the built Info.plist names no icon, when the
# compiled asset catalogue has no AppIcon, or when the source icon is not a
# 1024x1024 PNG without alpha.
# Usage: check_built_icon.sh APP_DIR SOURCE_ICON_PNG
# Needs macOS (PlistBuddy and xcrun assetutil). Prints names and counts only.
set -u

app="$1"
source_icon="$2"
plist="$app/Info.plist"
failed=0

python3 "$(dirname "$0")/check_icon.py" "$source_icon" || failed=1

icon_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconName" "$plist" 2> /dev/null || true)"
icon_dict="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIcons" "$plist" 2> /dev/null || true)"
echo "CFBundleIconName: ${icon_name:-<missing>}"
if [ -z "$icon_name" ] && [ -z "$icon_dict" ]; then
  echo "FAIL icon: the built Info.plist has neither CFBundleIconName nor CFBundleIcons"
  failed=1
fi

if [ ! -f "$app/Assets.car" ]; then
  echo "FAIL icon: the built app has no Assets.car"
  failed=1
else
  info="$(xcrun assetutil --info "$app/Assets.car" 2> /dev/null || true)"
  hits="$(printf '%s\n' "$info" | grep -c '"Name" : "AppIcon"' || true)"
  echo "Assets.car AppIcon renditions: $hits"
  if [ "$hits" = "0" ]; then
    echo "FAIL icon: Assets.car holds no AppIcon rendition"
    failed=1
  fi
fi

if [ "$failed" = "0" ]; then
  echo "PASS built icon"
  exit 0
fi
exit 1
