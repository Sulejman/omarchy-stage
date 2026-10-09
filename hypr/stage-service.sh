#!/bin/bash
# Runtime loader used by the Omarchy plugin (Service.qml). It never edits your
# Hyprland config: stage is loaded into the running Hyprland with `hyprctl eval`
# and loaded again after every config reload, which starts a fresh Lua state.
#
# Usage: stage-service.sh start   build/load the thumbnails plugin, load stage
#        stage-service.sh load    load stage only (after a config reload)
#        stage-service.sh stop    reload Hyprland so stage is gone

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$DIR/stagethumbs"
SO="$PLUGIN/stagethumbs.so"
STAMP="$PLUGIN/.built-for"

notify() {
  notify-send -a "Stage" "Stage layout" "$1" 2>/dev/null || true
  echo "stage: $1"
}

lua_quote() { # single-quoted Lua string
  local s=${1//\\/\\\\}
  printf "'%s'" "${s//\'/\\\'}"
}

load_stage() {
  hyprctl eval "_G.stage_runtime = true; dofile($(lua_quote "$DIR/stage.lua"))" >/dev/null
}

# Hyprland plugins must be built against the exact Hyprland that's installed.
# Rebuild when the package version changes; on failure, run without miniatures.
build_thumbs() {
  local want have
  want=$(pacman -Q hyprland 2>/dev/null | awk '{ print $2 }')
  have=$(cat "$STAMP" 2>/dev/null)
  [[ -n $want ]] || return 0
  [[ $want == "$have" ]] && return 0

  if ! command -v make >/dev/null || ! command -v g++ >/dev/null || ! pkg-config --exists hyprland 2>/dev/null; then
    echo "$want" >"$STAMP"
    notify "Miniature thumbnails need base-devel (make, g++). Stage works without them."
    return 0
  fi

  if make -B -C "$PLUGIN" >"$PLUGIN/build.log" 2>&1; then
    echo "$want" >"$STAMP"
  else
    rm -f "$SO"
    echo "$want" >"$STAMP"
    notify "Couldn't build the miniature-thumbnails plugin for Hyprland $want; thumbnails are plain. See $PLUGIN/build.log"
  fi
}

load_thumbs() {
  [[ -f $SO ]] || return 0
  hyprctl plugin list 2>/dev/null | grep -q '^Plugin stagethumbs ' && return 0
  hyprctl plugin load "$SO" >/dev/null
  sleep 0.5
}

case "${1:-start}" in
  start)
    load_stage # usable right away; the build can take a while
    build_thumbs
    # Loading a plugin re-runs the config (fresh Lua state), so load stage
    # again afterwards. Already loaded, it's a no-op.
    load_thumbs && load_stage
    ;;
  load)
    load_stage
    ;;
  stop)
    # A reload drops the layout and its binds. The thumbnails plugin stays
    # loaded until logout, but only acts on stage workspaces, so it is idle.
    hyprctl reload >/dev/null
    ;;
  *)
    echo "usage: $0 start|load|stop" >&2
    exit 1
    ;;
esac
