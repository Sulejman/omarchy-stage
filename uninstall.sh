#!/bin/bash
# Remove the stage layout and everything install.sh added.

set -euo pipefail

HYPR="$HOME/.config/hypr"
CONFIG="$HYPR/hyprland.lua"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/hypr-stage"

if [[ -f $CONFIG ]]; then
  # Drop the require line and the comment install.sh put above it.
  sed -i -e '/^-- Stage Manager-style layout, added to the SUPER+L layout cycle/d' \
    -e '/^require("hypr\.stage")$/d' "$CONFIG"
fi

rm -f "$HYPR/stage.lua" "$HYPR/stage-maintain.sh"
rm -rf "$HYPR/stagethumbs" "$STATE"
rm -f "$HOME/.config/omarchy/hooks/post-update.d/hypr-stage-update.hook" \
  "$HOME/.config/omarchy/hooks/post-boot.d/hypr-stage-boot.hook"

# Reloading also unloads the thumbnails plugin, since nothing registers it anymore,
# and stage workspaces fall back to the default layout.
if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null
fi

echo "Stage removed. Backups (*.bak.*) in $HYPR were left in place."
