#!/bin/bash
# Install (or update) the stage layout into ~/.config/hypr.
#
# Safe to re-run: `git pull && ./install.sh` updates an existing install.
# Files that differ from the repo are backed up as <file>.bak.<timestamp>.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR="$HOME/.config/hypr"
CONFIG="$HYPR/hyprland.lua"
REQUIRE='require("hypr.stage")'
STAMP=$(date +%s)

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- checks ------------------------------------------------------------------

command -v omarchy >/dev/null || die "Omarchy not found. Stage uses Omarchy's bind helpers and layout toggle."
[[ -f $CONFIG ]] || die "$CONFIG not found. Stage needs Hyprland's Lua config (Hyprland 0.56+)."
[[ -d $HOME/.config/omarchy/plugins/io.github.sulejman.stage ]] &&
  die "Stage is installed as an Omarchy plugin already. Use one or the other: omarchy plugin remove io.github.sulejman.stage"

version=$(pacman -Q hyprland 2>/dev/null | awk '{ print $2 }' || true)
if [[ -n $version ]] && [[ $(printf '%s\n0.56\n' "${version%%-*}" | sort -V | head -1) != 0.56 ]]; then
  die "Hyprland $version is too old; stage needs 0.56 or newer."
fi

# --- files -------------------------------------------------------------------

put() { # put <repo path> <destination> [mode]
  local from="$SRC/$1" to="$2" mode="${3:-644}"
  mkdir -p "$(dirname "$to")"
  if [[ -f $to ]] && ! cmp -s "$from" "$to"; then
    cp -f "$to" "$to.bak.$STAMP"
    echo "  backed up $to -> $to.bak.$STAMP"
  fi
  install -m "$mode" "$from" "$to"
}

say "Installing stage into $HYPR"
put hypr/stage.lua "$HYPR/stage.lua"
put hypr/stage-maintain.sh "$HYPR/stage-maintain.sh" 755
put hypr/stagethumbs/main.cpp "$HYPR/stagethumbs/main.cpp"
put hypr/stagethumbs/Makefile "$HYPR/stagethumbs/Makefile"

say "Installing Omarchy hooks (rebuild after updates, repair after config resets)"
omarchy hook install post-update "$SRC/hooks/hypr-stage-update.hook" >/dev/null
omarchy hook install post-boot "$SRC/hooks/hypr-stage-boot.hook" >/dev/null

if ! grep -Fqx "$REQUIRE" "$CONFIG"; then
  cp -f "$CONFIG" "$CONFIG.bak.$STAMP"
  printf '\n-- Stage Manager-style layout, added to the SUPER+L layout cycle. Delete this line + stage.lua to remove.\n%s\n' "$REQUIRE" >>"$CONFIG"
  echo "  added $REQUIRE to $CONFIG (backup: $CONFIG.bak.$STAMP)"
fi

# --- miniature thumbnails plugin (optional) ----------------------------------

say "Building the miniature-thumbnails plugin"
if ! command -v make >/dev/null || ! command -v g++ >/dev/null; then
  echo "  skipped: needs make and g++ (the base-devel package group)."
  echo "  Stage works without it; thumbnails are then plain small windows."
elif ! pkg-config --exists hyprland 2>/dev/null; then
  echo "  skipped: Hyprland headers not found by pkg-config."
  echo "  Stage works without it; thumbnails are then plain small windows."
else
  # Force a rebuild: main.cpp may have changed even if Hyprland didn't.
  rm -f "$HYPR/stagethumbs/.built-for"
  "$HYPR/stage-maintain.sh" update | sed 's/^/  /'
fi

if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null
  errors=$(hyprctl configerrors 2>/dev/null | grep -v '^$' || true)
  [[ -n $errors ]] && printf 'Hyprland reports config errors:\n%s\n' "$errors" >&2
fi

say "Done. Press SUPER+L to cycle a workspace through dwindle -> scrolling -> stage."
