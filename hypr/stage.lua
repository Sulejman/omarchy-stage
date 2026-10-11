-- Stage: a Stage Manager-style layout for Hyprland.
--
-- The window you're using sits alone in the middle of the screen. Every
-- other window on the workspace becomes a thumbnail in columns on the left
-- and right. Thumbnails are as big as the space allows: a few windows get one
-- column of large thumbnails, and more columns appear only when needed.
--
-- Thumbnails keep their spot. Bringing a window into the middle only swaps
-- it with the current middle window; nothing else moves.
--   click a thumbnail      swap it into the middle
--   ALT + TAB              hold ALT, tap TAB to move the highlight across the
--   ALT + SHIFT + TAB      thumbnails (left side, then right); release ALT
--                          to open it
--   SUPER + arrows         move focus without moving anything (you can type
--                          into a focused thumbnail)
--   SUPER + Z              swap the focused thumbnail into the middle
--   SUPER + - / =          widen / narrow the middle window (ALT: a little,
--                          CTRL: a lot); thumbnails resize to use the
--                          space that's left
--
-- SUPER + L cycles the current workspace through dwindle -> scrolling ->
-- stage -> dwindle. The dwindle/scrolling steps are still Omarchy's own
-- omarchy-hyprland-workspace-layout-toggle; this file only adds the stage step.
--
-- Inspired by Scott Jenson's talk "Are we really going to use the same Desktop
-- UX forever?" (https://www.youtube.com/watch?v=V7AfAcQwLW0).
--
-- From https://github.com/Sulejman/omarchy-stage. As an Omarchy plugin it is
-- loaded at runtime and removed with `omarchy plugin remove
-- io.github.sulejman.stage`. A manual install (install.sh) is removed with
-- uninstall.sh, or by hand:
--   1. delete the `require("hypr.stage")` line in ~/.config/hypr/hyprland.lua
--   2. rm ~/.config/hypr/stage.lua
--   3. rm -r ~/.local/state/hypr-stage ~/.config/hypr/stagethumbs
--   4. hyprctl plugin unload ~/.config/hypr/stagethumbs/stagethumbs.so (or log out)

-- Loaded once per Hyprland Lua state. A config reload starts a fresh state,
-- so this only stops a second copy (e.g. both the Omarchy plugin and a manual
-- `require`) from registering everything twice.
if _G.omarchy_stage then
  return _G.omarchy_stage
end

local cfg = {
  center_aspect = 1.6, -- preferred width:height of the middle window...
  center_min = 0.40, -- ...but never less than this share of the screen width
  center_max = 0.64, -- ...and never more
  decay = 0.75, -- each thumbnail column further out is this much narrower
  center_step_min = 0.25, -- the middle window can be resized between these shares of the width
  center_step_max = 0.92,

  thumb_opacity = 0.72, -- thumbnails at rest; the selected or hovered one is fully opaque
  select_border = 4, -- border (px) on thumbnails; only the selected one's is visible
  swap_flash_ms = 700, -- both windows of a swap light up this long, so it's clear which two traded places
}

local LAYOUT = "lua:stage"
local OMARCHY_TOGGLE = "omarchy-hyprland-workspace-layout-toggle"
-- Nerd Font md-view_carousel_outline: one window in the middle, others at the
-- sides. Shown like the icons on Omarchy's dwindle/scrolling notifications.
local STAGE_ICON = "\u{F1486}"
local state_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/hypr-stage"
local state_file = state_dir .. "/workspaces"
local error_file = state_dir .. "/errors.log"

-- Hyprland shows callback errors only in its error bar, and every config
-- reload clears that. Keep a copy, with a traceback, that survives.
local function guarded(fn)
  return function(...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if ok then
      return err
    end
    os.execute("mkdir -p '" .. state_dir .. "'")
    local file = io.open(error_file, "a")
    if file then
      file:write(os.date("%Y-%m-%d %H:%M:%S "), tostring(err), "\n\n")
      file:close()
    end
    error(err, 0)
  end
end

-- Focus changes that mean "put this window in the middle". Keyboard
-- navigation (SUPER + arrows), hover, workspace switches and windows closing
-- don't count; SUPER + Z promotes explicitly.
local DELIBERATE = {
  [3] = true, -- focus dispatcher (window switchers, notifications)
  [5] = true, -- click
  [8] = true, -- switch to window (soft)
  [9] = true, -- switch to window (hard)
  [16] = true, -- new window
}

-- workspace id -> list of window stable_ids. [1] is the window in the
-- middle; [2], [3], ... are thumbnail slots (alternating left and right,
-- inner column first). Windows only change slot when swapped.
local slots = {}

local function index_of(list, value)
  for i, v in ipairs(list) do
    if v == value then
      return i
    end
  end
end

-- Opening order (stable ids only grow): who takes the middle when the middle
-- window closes, and the slot order when a workspace is first seen.
local function sequence(list)
  local seq = {}
  for i, id in ipairs(list) do
    seq[i] = id
  end
  table.sort(seq)
  return seq
end

-- Bring the window with this id into the middle by swapping it with the
-- current middle window. Unknown windows take a new slot first.
local function swap_in(list, id)
  local j = index_of(list, id)
  if not j then
    list[#list + 1] = id
    j = #list
  end
  list[1], list[j] = list[j], list[1]
end

-- Make the slot list match the windows that are actually there.
local function sync(list, windows, focused_id)
  local present = {}
  for _, w in ipairs(windows) do
    present[w.stable_id] = true
  end

  -- A window that left: the last thumbnail fills its slot, so at most one
  -- other window moves. If it was the middle one, the next window in the
  -- Alt+Tab order takes the middle.
  local i = 1
  while i <= #list do
    local id = list[i]
    if present[id] then
      i = i + 1
    elseif i == 1 and #list > 1 then
      local rest = {}
      for k = 2, #list do
        if present[list[k]] then
          rest[#rest + 1] = list[k]
        end
      end
      if #rest == 0 then
        table.remove(list, 1)
      else
        local successor = sequence(rest)[1]
        for _, cand in ipairs(sequence(rest)) do
          if cand > id then
            successor = cand
            break
          end
        end
        local j = index_of(list, successor)
        list[1] = successor
        if j == #list then
          table.remove(list)
        else
          list[j] = table.remove(list)
        end
      end
    elseif i == #list then
      table.remove(list)
    else
      list[i] = table.remove(list)
    end
  end

  -- First time this workspace is seen (e.g. after a config reload): the
  -- focused window goes in the middle, the rest in opening order.
  if #list == 0 then
    for _, id in ipairs(sequence((function()
      local ids = {}
      for _, w in ipairs(windows) do
        ids[#ids + 1] = w.stable_id
      end
      return ids
    end)())) do
      list[#list + 1] = id
    end
    if focused_id and index_of(list, focused_id) then
      swap_in(list, focused_id)
    end
    return
  end

  for _, w in ipairs(windows) do
    if not index_of(list, w.stable_id) then
      list[#list + 1] = w.stable_id
    end
  end
end

local function slots_for(ws_id)
  slots[ws_id] = slots[ws_id] or {}
  return slots[ws_id]
end

-- workspace id -> how much wider (+) or narrower (-) than the default the
-- middle window is, as a share of the screen width. Changed with the resize
-- keys and kept in a state file so config reloads don't reset it.
local center_file = state_dir .. "/center"
local center_adjust = {}
do
  local file = io.open(center_file, "r")
  if file then
    for line in file:lines() do
      local id, adjust = line:match("^(%-?%d+)%s+(%-?[%d.e+-]+)$")
      if id then
        center_adjust[tonumber(id)] = tonumber(adjust)
      end
    end
    file:close()
  end
end

local function save_center()
  os.execute("mkdir -p '" .. state_dir .. "'")
  local file = io.open(center_file, "w")
  if not file then
    return
  end
  for id, adjust in pairs(center_adjust) do
    file:write(id, " ", adjust, "\n")
  end
  file:close()
end

local function default_share(area)
  return math.min(cfg.center_max, math.max(cfg.center_min, cfg.center_aspect / (area.w / area.h)))
end

local function center_share(area, ws_id)
  local share = default_share(area) + (center_adjust[ws_id] or 0)
  return math.min(cfg.center_step_max, math.max(cfg.center_step_min, share))
end

-- Width of each side of the middle window.
local function side_geometry(area, ws_id)
  return area.w * (1 - center_share(area, ws_id)) / 2
end

-- Lay out one side's thumbnails, shaped like the middle window (so they are
-- true miniatures of it). Columns get smaller going outward (`decay`), and
-- inner columns fill first, top to bottom; each column is centred vertically.
-- For 1, 2, 3, ... columns, find the biggest inner column that still fits all
-- thumbnails, and keep the column count where that is biggest (fewer unless
-- more are clearly better): a few windows get one column of big thumbnails, and more columns only
-- appear once a column would get too crowded.
-- `inner` is the x of the edge facing the middle; `dir` is -1 (left) or 1.
local function fill_side(targets, area, inner, side_w, dir, aspect)
  local n = #targets
  if n == 0 then
    return
  end

  -- How many thumbnails each of `cols` columns holds when the inner one is w1 wide.
  local function capacities(w1, cols)
    local caps, total, w = {}, 0, w1
    for k = 1, cols do
      caps[k] = math.floor(area.h * aspect / w)
      total = total + caps[k]
      w = w * cfg.decay
    end
    return caps, total
  end

  local best
  for cols = 1, n do
    local span = (1 - cfg.decay ^ cols) / (1 - cfg.decay)
    local hi = math.min(side_w / span, area.h * aspect)
    local _, total = capacities(hi, cols)
    local w1 = hi
    if total < n then
      local lo = 0
      for _ = 1, 40 do
        local mid = (lo + hi) / 2
        if select(2, capacities(mid, cols)) >= n then
          lo = mid
        else
          hi = mid
        end
      end
      w1 = lo
    end
    -- Another column has to be clearly better (5%) to be worth adding.
    if not best or w1 > best.w1 * 1.05 then
      best = { w1 = w1, cols = cols }
    end
  end

  local caps = capacities(best.w1, best.cols)
  local x, i, w = inner, 1, best.w1
  for c = 1, best.cols do
    local count = math.min(caps[c], n - i + 1)
    if c == best.cols then
      count = n - i + 1 -- rounding: the last column takes what's left
    end
    local th = math.min(w / aspect, area.h / math.max(count, 1))
    local tw = th * aspect
    local tx = dir < 0 and (x - tw) or x
    local y = area.y + (area.h - th * count) / 2
    for j = 0, count - 1 do
      targets[i + j]:place({ x = tx, y = y + j * th, w = tw, h = th })
    end
    i = i + count
    x = x + dir * w
    w = w * cfg.decay
  end
end

-- The optional stagethumbs plugin (~/.config/hypr/stagethumbs) turns
-- thumbnails into real miniatures: the app keeps its full size and is drawn
-- scaled down. Without it, thumbnails are just small windows.
local function thumbs()
  return hl.plugin and hl.plugin.stagethumbs
end

-- Register it on every config run while it is built. hl.plugin.load only adds
-- the path to Hyprland's wanted list; after each run Hyprland loads what is
-- listed and unloads what isn't. Registering it conditionally (e.g. "only if
-- not loaded yet") makes it flip between loaded and unloaded forever, which
-- freezes Hyprland.
--
-- When the Omarchy plugin loads this file at runtime (hyprctl eval), it sets
-- stage_runtime and loads the .so itself with `hyprctl plugin load`, which
-- survives config reloads; hl.plugin.load only takes effect during a config run.
local here = debug.getinfo(1, "S").source:match("^@(.*/)") or (os.getenv("HOME") .. "/.config/hypr/")
local plugin_so = here .. "stagethumbs/stagethumbs.so"
local built = io.open(plugin_so, "r")
if built then
  built:close()
  if not _G.stage_runtime then
    hl.plugin.load(plugin_so)
  end
end

local function show_full(target)
  local p = thumbs()
  local address = target.window and target.window.address
  if p and address then
    p.clear(address)
  end
end

local function show_thumbnail(target, w, h)
  local p = thumbs()
  local address = target.window and target.window.address
  if p and address then
    p.set(address, w, h)
  end
end

hl.layout.register("stage", {
  recalculate = guarded(function(ctx)
    if #ctx.targets == 0 then
      return
    end

    local windows, by_id, others = {}, {}, {}
    for _, t in ipairs(ctx.targets) do
      local w = t.window
      if w and w.stable_id and w.workspace then
        windows[#windows + 1] = w
        by_id[w.stable_id] = t
      else
        others[#others + 1] = t
      end
    end

    local middle, side = nil, {}
    if #windows > 0 then
      local list = slots_for(windows[1].workspace.id)
      local active = hl.get_active_window()
      sync(list, windows, active and active.stable_id)
      middle = by_id[list[1]]
      for k = 2, #list do
        side[#side + 1] = by_id[list[k]]
      end
    end
    for _, t in ipairs(others) do
      if middle then
        side[#side + 1] = t
      else
        middle = t
      end
    end

    local area = ctx.area
    if #side == 0 then
      show_full(middle)
      middle:place(area)
      return
    end

    local ws_id = windows[1] and windows[1].workspace.id
    local side_w = side_geometry(area, ws_id)
    local mid_w = area.w - 2 * side_w
    if middle then
      show_full(middle)
      middle:place({ x = area.x + side_w, y = area.y, w = mid_w, h = area.h })
    end

    -- Thumbnails are miniatures of how the window looks in the middle at its
    -- default width, so resizing the middle doesn't change their shape.
    local thumb_w = area.w * default_share(area)
    for _, t in ipairs(side) do
      show_thumbnail(t, thumb_w, area.h)
    end

    -- Alternate sides so both stay balanced; slot order fixes the positions.
    local left, right = {}, {}
    for k, t in ipairs(side) do
      local list = k % 2 == 1 and left or right
      list[#list + 1] = t
    end
    local aspect = thumb_w / area.h
    fill_side(left, area, area.x + side_w, side_w, -1, aspect)
    fill_side(right, area, area.x + area.w - side_w, side_w, 1, aspect)
  end),

  layout_msg = function(_, msg)
    if msg ~= "refresh" then
      return "stage: expected refresh"
    end
    return true
  end,
})

-- Persisted list of workspaces in stage mode. Omarchy restores its own
-- dwindle/scrolling choice earlier in the config; this runs later, so stage wins.

local function read_state()
  local set = {}
  local file = io.open(state_file, "r")
  if file then
    for line in file:lines() do
      if line ~= "" then
        set[line] = true
      end
    end
    file:close()
  end
  return set
end

local function write_state(set)
  os.execute("mkdir -p " .. o.shell_quote(state_dir))
  local file = io.open(state_file, "w")
  if not file then
    return
  end
  for ws in pairs(set) do
    file:write(ws, "\n")
  end
  file:close()
end

local function selector(ws)
  return ws.id > 0 and tostring(ws.id) or ("name:" .. ws.name)
end

for ws in pairs(read_state()) do
  hl.workspace_rule({ workspace = ws, layout = LAYOUT })
end

local function is_stage(ws)
  return ws and not ws.special and ws.tiled_layout == LAYOUT
end

local function tiled_windows(ws)
  local windows = {}
  for _, w in ipairs(hl.get_workspace_windows(selector(ws))) do
    if w.mapped and not w.floating then
      windows[#windows + 1] = w
    end
  end
  return windows
end

-- Layout messages go to whatever layout owns the focused window, so only
-- send one when that is a tiled window on a stage workspace. Anything else
-- would land on dwindle and show up as an error.
local function stage_focused()
  local w = hl.get_active_window()
  if w and w.mapped and not w.floating and is_stage(w.workspace) then
    return w.workspace
  end
end

-- Thumbnails must not grab focus just because the mouse passes over them,
-- or a later click on them wouldn't register as a new focus. They also carry
-- the "stage-thumb" tag, which the highlight rules below style. The tag itself
-- is the source of truth (it survives config reloads, a Lua table wouldn't);
-- the hover block is always set together with it.
local function has_tag(window, name)
  for _, tag in ipairs(type(window.tags) == "table" and window.tags or {}) do
    if tag == name or tag == name .. "*" then
      return true
    end
  end
  return false
end

local function has_thumb_tag(window)
  return has_tag(window, "stage-thumb")
end

-- window: a window object or an "address:0x..." selector
local function tag_window(window, tag, on)
  hl.dispatch(hl.dsp.window.tag({ window = window, tag = (on and "+" or "-") .. tag }))
end

local function set_thumb(window, is_thumb)
  if not window or not window.stable_id or has_thumb_tag(window) == is_thumb then
    return
  end
  hl.dispatch(hl.dsp.window.set_prop({ window = window, prop = "no_follow_mouse", value = is_thumb and "1" or "0" }))
  tag_window(window, "stage-thumb", is_thumb)
  if not is_thumb and has_tag(window, "stage-hover") then
    tag_window(window, "stage-hover", false)
  end
end

local function update_thumbs(ws)
  local list = slots[ws.id] or {}
  for _, w in ipairs(tiled_windows(ws)) do
    set_thumb(w, list[1] ~= w.stable_id)
  end
end

-- Highlighting, all done with tags and window rules: taking a tag off puts the
-- window straight back under Omarchy's own opacity and border rules.
--   stage-thumb  every thumbnail: dimmed unless focused; the focused one (e.g.
--                reached with SUPER + arrows) gets a thick border in the
--                theme's active border colour, the others an invisible one
--   stage-hover  the thumbnail under the mouse: opaque, softer border
--   stage-swap   both windows of a swap, briefly: border in the accent colour.
--                Colour only, so no window changes size (and re-lays out) for it
local function accent(alpha)
  local ok, opt = pcall(hl.get_config, "general.col.active_border")
  local argb = ok and type(opt) == "table" and type(opt.colors) == "table" and opt.colors[1]
  local rgb = type(argb) == "string" and argb:match("^0[xX]%x%x(%x%x%x%x%x%x)$") or "ffffff"
  return "rgba(" .. rgb .. alpha .. ")"
end

o.window({ tag = "stage-thumb" }, {
  opacity = "1.0 " .. cfg.thumb_opacity,
  border_size = cfg.select_border,
  border_color = accent("ff") .. " rgba(00000000)",
})
o.window({ tag = "stage-hover" }, {
  opacity = "1.0 1.0",
  border_color = accent("ff") .. " " .. accent("99"),
})
o.window({ tag = "stage-swap" }, {
  opacity = "1.0 1.0",
  border_color = accent("ff") .. " " .. accent("ff"),
})

-- Flash both windows of a swap. A window flashed again before its last flash
-- ended keeps the newer one; a window that closed meanwhile is skipped.
local flash_gen = {}
local function flash(ws, ids)
  local want = {}
  for _, id in ipairs(ids) do
    want[id] = true
  end
  for _, w in ipairs(tiled_windows(ws)) do
    if want[w.stable_id] then
      local target = "address:" .. w.address
      local gen = (flash_gen[target] or 0) + 1
      flash_gen[target] = gen
      tag_window(target, "stage-swap", true)
      hl.timer(guarded(function()
        if flash_gen[target] == gen then
          flash_gen[target] = nil
          pcall(tag_window, target, "stage-swap", false)
        end
      end), { timeout = cfg.swap_flash_ms, type = "oneshot" })
    end
  end
end

-- swap_in plus the flash, for swaps the user caused
local function swap_and_flash(ws, list, id)
  local old = list[1]
  swap_in(list, id)
  if old and old ~= id then
    flash(ws, { old, id })
  end
end

-- Focus events fire mid-update; act on the next tick, once state has settled.
local pending = false
local function relayout_soon()
  if pending then
    return
  end
  pending = true
  hl.timer(guarded(function()
    pending = false
    local ws = stage_focused()
    if ws then
      hl.dispatch(hl.dsp.layout("refresh"))
      update_thumbs(ws)
    end
  end), { timeout = 1, type = "oneshot" })
end

-- Set while stage navigation moves focus, so that focus isn't a promotion.
local navigating = false

hl.on("window.active", guarded(function(window, reason)
  if navigating or not window or not window.stable_id or not DELIBERATE[reason] then
    return
  end
  if not is_stage(window.workspace) or window.floating then
    return
  end
  swap_and_flash(window.workspace, slots_for(window.workspace.id), window.stable_id)
  relayout_soon()
end))

hl.on("window.close", guarded(relayout_soon))

hl.on("window.destroy", guarded(function(window)
  show_full({ window = window })
end))

-- A thumbnail moved to a non-stage workspace becomes a normal window again.
-- After a config reload, bring tags in line with the current slots.
hl.timer(guarded(function()
  local ws = hl.get_active_workspace()
  if is_stage(ws) then
    if stage_focused() then
      hl.dispatch(hl.dsp.layout("refresh"))
    end
    update_thumbs(ws)
    -- A reload mid-flash would strand the swap highlight.
    for _, w in ipairs(tiled_windows(ws)) do
      if has_tag(w, "stage-swap") then
        tag_window(w, "stage-swap", false)
      end
    end
  end
end), { timeout = 200, type = "oneshot" })

hl.on("window.move_to_workspace", guarded(function(window)
  if window and not is_stage(window.workspace) then
    set_thumb(window, false)
    show_full({ window = window })
  end
end))


local M = {}

-- Swap the focused thumbnail into the middle.
function M.promote()
  local w = hl.get_active_window()
  local ws = stage_focused()
  if w and ws and w.stable_id then
    swap_and_flash(ws, slots_for(ws.id), w.stable_id)
    relayout_soon()
  end
end

-- dwindle -> scrolling -> stage -> dwindle
function M.cycle()
  local ws = hl.get_active_workspace()
  if not ws or ws.special then
    return
  end

  local set = read_state()
  local key = selector(ws)

  if ws.tiled_layout == "scrolling" then
    set[key] = true
    write_state(set)
    hl.workspace_rule({ workspace = key, layout = LAYOUT })
    update_thumbs(ws)
    hl.exec_cmd("omarchy-notification-send -g " .. STAGE_ICON .. " 'Workspace layout set to stage'")
    return
  end

  if ws.tiled_layout == LAYOUT then
    set[key] = nil
    write_state(set)
    for _, w in ipairs(tiled_windows(ws)) do
      set_thumb(w, false)
      show_full({ window = w })
    end
  end

  -- From stage or dwindle, Omarchy's toggle does the rest (and remembers it).
  hl.exec_cmd(OMARCHY_TOGGLE)
end

-- Hyprland's own directional focus only links windows whose edges touch,
-- which thumbnails separated by gaps never do. On stage workspaces pick the
-- nearest window in that direction instead; elsewhere keep the normal focus.
local DIRECTIONS = {
  l = { x = -1, y = 0 },
  r = { x = 1, y = 0 },
  u = { x = 0, y = -1 },
  d = { x = 0, y = 1 },
}

local function centre(w)
  return w.at.x + w.size.x / 2, w.at.y + w.size.y / 2
end

function M.focus(dir)
  return function()
    local ws = stage_focused()
    if not ws then
      hl.dispatch(hl.dsp.focus({ direction = dir }))
      return
    end

    local current = hl.get_active_window()
    local cx, cy = centre(current)
    local v = DIRECTIONS[dir]
    local best, best_score

    for _, w in ipairs(tiled_windows(ws)) do
      if w.stable_id ~= current.stable_id then
        local x, y = centre(w)
        local along = (x - cx) * v.x + (y - cy) * v.y
        local across = math.abs((x - cx) * v.y + (y - cy) * v.x)
        -- Only windows within ~60 degrees of straight ahead; favour the closest.
        if along > 1 and across <= 2 * along then
          local score = along + 2 * across
          if not best_score or score < best_score then
            best, best_score = w, score
          end
        end
      end
    end

    if best then
      navigating = true
      hl.dispatch(hl.dsp.focus({ window = best }))
      navigating = false
    end
  end
end

-- Alt+Tab on a stage workspace is a switcher: while ALT is held, each TAB
-- moves the highlight (keyboard focus, which gives the thumbnail its border)
-- to the next thumbnail in screen order: the whole left side first (inner
-- column top to bottom, then the outer ones), then the right side the same
-- way. SHIFT goes backwards.
-- Releasing ALT opens the highlighted window into the middle (one swap).
-- Elsewhere, Omarchy's own Alt+Tab.
local switching = nil -- { ws = workspace id, p = position in the order } while ALT is held

-- Slot indices in switcher order. Slots alternate sides (2 left, 3 right,
-- 4 left, ...) and each side fills its inner column first.
local function switch_order(n)
  local order = {}
  for start = 2, 3 do
    for k = start, n, 2 do
      order[#order + 1] = k
    end
  end
  return order
end

function M.tab(step)
  return function()
    local ws = stage_focused()
    if not ws then
      hl.dispatch(hl.dsp.window.cycle_next({ next = step > 0 }))
      hl.dispatch(hl.dsp.window.bring_to_top())
      return
    end

    local list = slots_for(ws.id)
    local windows = tiled_windows(ws)
    local active = hl.get_active_window()
    sync(list, windows, active and active.stable_id)
    local n = #list
    if n < 2 then
      return
    end

    local order = switch_order(n)
    if not switching or switching.ws ~= ws.id then
      switching = { ws = ws.id, p = step > 0 and 0 or #order + 1 }
    end
    local p = switching.p + step
    if p > #order then
      p = 1
    elseif p < 1 then
      p = #order
    end
    switching.p = p
    local k = order[p]

    for _, w in ipairs(windows) do
      if w.stable_id == list[k] then
        navigating = true
        hl.dispatch(hl.dsp.focus({ window = w }))
        navigating = false
        return
      end
    end
  end
end

-- ALT released: open the highlighted thumbnail.
function M.tab_commit()
  local sw = switching
  switching = nil
  local ws = sw and stage_focused()
  if not ws or ws.id ~= sw.ws then
    return
  end
  local w = hl.get_active_window()
  local list = slots_for(ws.id)
  if w and w.stable_id and list[1] ~= w.stable_id then
    swap_and_flash(ws, list, w.stable_id)
    relayout_soon()
  end
end

-- Omarchy's horizontal resize keys. On a stage workspace they widen or narrow
-- the middle window (kept centred); elsewhere they resize as usual.
function M.resize(dx)
  return function()
    local ws = stage_focused()
    if not ws then
      hl.dispatch(hl.dsp.window.resize({ x = dx, y = 0, relative = true }))
      return
    end

    local mon = ws.monitor
    local width = mon and (mon.width / mon.scale) or 1920
    -- Omarchy's "expand" is a negative x; widen by that much on each side.
    local share = default_share({ w = width, h = mon and (mon.height / mon.scale) or 1080 })
    local adjust = (center_adjust[ws.id] or 0) - 2 * dx / width
    -- clamp so repeated presses past a limit don't pile up
    adjust = math.min(cfg.center_step_max - share, math.max(cfg.center_step_min - share, adjust))
    center_adjust[ws.id] = adjust
    save_center()
    hl.dispatch(hl.dsp.layout("refresh"))
  end
end

-- Called by the stagethumbs plugin when the pointer moves onto a thumbnail
-- (its address) or off all of them (""). Hyprland has no hover event for Lua.
-- Every window on the workspace is brought in line, so a highlight left over
-- from before a config reload is cleared too.
function M.hover(address)
  local ws = hl.get_active_workspace()
  if not is_stage(ws) then
    return
  end
  for _, w in ipairs(tiled_windows(ws)) do
    local want = address ~= "" and w.address == address and has_thumb_tag(w)
    if has_tag(w, "stage-hover") ~= want then
      tag_window(w, "stage-hover", want)
    end
  end
end

hl.unbind("SUPER + L")
o.bind("SUPER + L", "Cycle workspace layout (dwindle, scrolling, stage)", guarded(M.cycle))
o.bind("SUPER + Z", "Stage: swap focused thumbnail into the middle", guarded(M.promote))

for _, k in ipairs({
  { "SUPER", -100, 100, "" },
  { "SUPER + ALT", -25, 25, " a little" },
  { "SUPER + CTRL", -300, 300, " a lot" },
}) do
  hl.unbind(k[1] .. " + code:20")
  hl.unbind(k[1] .. " + code:21")
  o.bind(k[1] .. " + code:20", "Expand window left" .. k[4], guarded(M.resize(k[2])))
  o.bind(k[1] .. " + code:21", "Shrink window left" .. k[4], guarded(M.resize(k[3])))
end

hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + TAB", "Focus on next window", guarded(M.tab(1)))
o.bind("ALT + SHIFT + TAB", "Focus on previous window", guarded(M.tab(-1)))
-- Releasing either ALT (with or without SHIFT still down) ends the switcher.
-- Bound with and without the modifiers, since whether ALT still counts as
-- held at its own release isn't something to rely on; tab_commit only acts
-- once. non_consuming: apps still see the key, so ALT works as usual.
for _, key in ipairs({ "Alt_L", "Alt_R" }) do
  for _, mods in ipairs({ "", "ALT + ", "ALT + SHIFT + " }) do
    o.bind(mods .. key, "Stage: open the window picked with Alt+Tab", guarded(M.tab_commit),
      { release = true, non_consuming = true, ignore_mods = true })
  end
end

for key, dir in pairs({ LEFT = "l", RIGHT = "r", UP = "u", DOWN = "d" }) do
  local name = ({ l = "left", r = "right", u = "above", d = "below" })[dir]
  hl.unbind("SUPER + " .. key)
  o.bind("SUPER + " .. key, "Focus on " .. name .. " window", guarded(M.focus(dir)))
end

_G.omarchy_stage = M
return M
