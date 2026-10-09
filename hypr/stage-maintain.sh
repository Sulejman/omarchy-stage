#!/bin/bash
# Keeps the stage layout (~/.config/hypr/stage.lua) working across Omarchy and
# Hyprland updates. Run by two Omarchy hooks:
#   ~/.config/omarchy/hooks/post-update.d/hypr-stage.hook  (after omarchy update)
#   ~/.config/omarchy/hooks/post-boot.d/hypr-stage.hook    (at every login)
#
#  1. If an update or `omarchy refresh hyprland` reset hyprland.lua, put the
#     require("hypr.stage") line back. Only while stage.lua exists, so deleting
#     stage.lua is still how you remove the setup.
#  2. Rebuild the stagethumbs plugin whenever the Hyprland package version
#     changed. If the build fails, disable the plugin (stage keeps working with
#     plain thumbnails) and say so, instead of leaving a stale build around.
#
# Usage: stage-maintain.sh [update|boot]   ("boot" also reloads Hyprland after a
# rebuild so the new plugin loads right away)

set -u

HYPR="$HOME/.config/hypr"
CONFIG="$HYPR/hyprland.lua"
PLUGIN="$HYPR/stagethumbs"
SO="$PLUGIN/stagethumbs.so"
STAMP="$PLUGIN/.built-for"
REQUIRE='require("hypr.stage")'
MODE="${1:-update}"

notify() {
  if command -v omarchy-notification-send >/dev/null; then
    omarchy-notification-send "Stage layout" "$1" || true
  fi
  echo "stage: $1"
}

[[ -f $HYPR/stage.lua ]] || exit 0

# 1. require line
if [[ -f $CONFIG ]] && ! grep -Fqx "$REQUIRE" "$CONFIG"; then
  printf '\n-- Stage Manager-style layout, added to the SUPER+L layout cycle. Delete this line + stage.lua to remove.\n%s\n' "$REQUIRE" >>"$CONFIG"
  notify "hyprland.lua was reset; stage layout re-enabled."
fi

# 2. plugin build
[[ -f $PLUGIN/main.cpp ]] || exit 0

want=$(pacman -Q hyprland 2>/dev/null | awk '{ print $2 }')
have=$(cat "$STAMP" 2>/dev/null)
[[ -n $want ]] || exit 0

if [[ $want == "$have" && -f $SO ]]; then
  exit 0
fi

if [[ $want == "$have" && -f $SO.disabled ]]; then
  exit 0 # already failed for this version; don't retry every login
fi

if make -B -C "$PLUGIN" >"$PLUGIN/build.log" 2>&1; then
  rm -f "$SO.disabled"
  echo "$want" >"$STAMP"
  notify "Rebuilt the miniature-thumbnails plugin for Hyprland $want."
  if [[ $MODE == boot ]] && command -v hyprctl >/dev/null; then
    hyprctl reload >/dev/null 2>&1 || true
  fi
else
  [[ -f $SO ]] && mv -f "$SO" "$SO.disabled"
  echo "$want" >"$STAMP"
  notify "Couldn't rebuild the miniature-thumbnails plugin for Hyprland $want; thumbnails are plain until it's fixed. See $PLUGIN/build.log"
fi
