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
if [ "$icon_name" != "AppIcon" ]; then
  echo "FAIL icon: the built Info.plist must name the AppIcon asset in CFBundleIconName"
  failed=1
fi
echo "CFBundleIcons present: $([ -n "$icon_dict" ] && echo yes || echo no)"
# Icon related keys, names only, to show what App Store Connect will read.
plutil -p "$plist" 2> /dev/null | grep -i "icon" | sed 's/^ *//' | cut -c1-120 || true

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
