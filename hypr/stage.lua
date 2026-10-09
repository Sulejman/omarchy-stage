-- Stage: a Stage Manager-style layout for Hyprland.
--
-- The window you're using sits alone in the middle of the screen. Every
-- other window on the workspace becomes a thumbnail in columns on the left
-- and right. A normal 16:9/16:10 screen gets one column per side; wider
-- screens get more, each further column smaller than the last, so they stay
-- visible in your peripheral vision.
--
-- Thumbnails keep their spot. Bringing a window into the middle only swaps
-- it with the current middle window; nothing else moves.
--   click a thumbnail      swap it into the middle
--   ALT + TAB              next window in a fixed order (the order they
--   ALT + SHIFT + TAB      were opened), so repeated presses visit them all
--   SUPER + arrows         move focus without moving anything (you can type
--                          into a focused thumbnail)
--   SUPER + Z              swap the focused thumbnail into the middle
--   SUPER + - / =          widen / narrow the middle window (ALT: a little,
--                          CTRL: a lot); the freed space fills with more,
--                          smaller thumbnail columns
--
-- SUPER + L cycles the current workspace through dwindle -> scrolling ->
-- stage -> dwindle. The dwindle/scrolling steps are still Omarchy's own
-- omarchy-hyprland-workspace-layout-toggle; this file only adds the stage step.
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
  column_h = 0.33, -- inner thumbnail column width, as a fraction of the screen height
  min_column_h = 0.08, -- columns narrower than this (fraction of height) aren't added
  decay = 0.65, -- each column further out is this much narrower, so its thumbnails are smaller and more fit
  center_step_min = 0.25, -- the middle window can be resized between these shares of the width
  center_step_max = 0.92,

  thumb_opacity = "0.85 0.85", -- thumbnails are a bit translucent, focused / unfocused
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

-- Alt+Tab order: the order windows were opened in (stable ids only grow).
local function sequence(list)
  local seq = {}
  for i, id in ipairs(list) do
    seq[i] = id
  end
  table.sort(seq)
  return seq
end

local function next_in_sequence(list, id, step)
  local seq = sequence(list)
  local i = index_of(seq, id)
  if not i or #seq == 0 then
    return seq[1]
  end
  return seq[(i - 1 + step) % #seq + 1]
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

-- Width of each side and of each thumbnail column (inner first). Columns keep
-- their natural width: the inner one is sized from the screen height, every
-- further one is `decay` narrower. A column is added once about a third of it
-- fits (all columns are then squeezed to fit) and never stretched, so
-- freeing up space adds columns instead of making thumbnails bigger.
local function side_geometry(area, ws_id)
  local side_w = area.w * (1 - center_share(area, ws_id)) / 2

  local widths, total = {}, 0
  local w = math.min(area.h * cfg.column_h, side_w)
  local min_w = area.h * cfg.min_column_h
  while w >= min_w and total + w * 0.3 <= side_w do
    widths[#widths + 1] = w
    total = total + w
    w = w * cfg.decay
  end

  if #widths == 0 then
    return side_w, { side_w }
  end
  if total > side_w then
    for k = 1, #widths do
      widths[k] = widths[k] * side_w / total
    end
  end
  return side_w, widths
end

-- Fill columns from the middle outward with thumbnails shaped like the
-- middle window (so they are true miniatures of it), stacked top to bottom
-- and centred vertically. The outermost
-- column takes any overflow and shrinks its thumbnails to fit.
-- `inner` is the x of the edge facing the middle; `dir` is -1 (left) or 1.
local function fill_side(targets, area, inner, widths, dir, aspect)
  local n = #targets
  if n == 0 then
    return
  end

  -- How many thumbnails each column holds at its size.
  local caps, total_cap = {}, 0
  for k, w in ipairs(widths) do
    caps[k] = math.max(1, math.floor(area.h / (w / aspect)))
    total_cap = total_cap + caps[k]
  end

  -- Spread thumbnails over the columns: one per column from the inside out,
  -- then each next one to the column that is least full for its size (inner
  -- wins ties). Outer, smaller columns hold more, so they take more. Past
  -- total capacity this keeps spreading the overflow and columns squeeze.
  local counts = {}
  for k = 1, #widths do
    counts[k] = k <= n and 1 or 0
  end
  for _ = #widths + 1, n do
    local best
    for k = 1, #widths do
      if not best or (counts[k] + 1) / caps[k] < (counts[best] + 1) / caps[best] then
        best = k
      end
    end
    counts[best] = counts[best] + 1
  end

  local x, i = inner, 1
  for c, w in ipairs(widths) do
    local count = counts[c]
    if count > 0 then
      local h = w / aspect
      local fit = math.min(1, area.h / (h * count))
      local tw, th = w * fit, h * fit
      local tx = dir < 0 and (x - tw) or x
      local y = area.y + (area.h - th * count) / 2
      for j = 0, count - 1 do
        targets[i + j]:place({ x = tx, y = y + j * th, w = tw, h = th })
      end
      i = i + count
    end
    x = x + dir * w
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
    local side_w, widths = side_geometry(area, ws_id)
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
    fill_side(left, area, area.x + side_w, widths, -1, aspect)
    fill_side(right, area, area.x + area.w - side_w, widths, 1, aspect)
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
-- the "stage-thumb" tag, which the window rule below makes more translucent.
-- The tag itself is the source of truth (it survives config reloads, a Lua
-- table wouldn't); the hover block is always set together with it.
local function has_thumb_tag(window)
  for _, tag in ipairs(type(window.tags) == "table" and window.tags or {}) do
    if tag == "stage-thumb" or tag == "stage-thumb*" then
      return true
    end
  end
  return false
end

local function set_thumb(window, is_thumb)
  if not window or not window.stable_id or has_thumb_tag(window) == is_thumb then
    return
  end
  hl.dispatch(hl.dsp.window.set_prop({ window = window, prop = "no_follow_mouse", value = is_thumb and "1" or "0" }))
  hl.dispatch(hl.dsp.window.tag({ window = window, tag = (is_thumb and "+" or "-") .. "stage-thumb" }))
end

local function update_thumbs(ws)
  local list = slots[ws.id] or {}
  for _, w in ipairs(tiled_windows(ws)) do
    set_thumb(w, list[1] ~= w.stable_id)
  end
end

o.window({ tag = "stage-thumb" }, { opacity = cfg.thumb_opacity })

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
  swap_in(slots_for(window.workspace.id), window.stable_id)
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
    swap_in(slots_for(ws.id), w.stable_id)
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

-- Alt+Tab on a stage workspace: the next window in opening order comes into
-- the middle (swapping places with the current one), so repeated presses
-- walk through every window. Elsewhere, Omarchy's own Alt+Tab.
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
    if #list < 2 then
      return
    end

    local target_id = next_in_sequence(list, list[1], step)
    local target
    for _, w in ipairs(windows) do
      if w.stable_id == target_id then
        target = w
      end
    end
    if not target then
      return
    end

    swap_in(list, target_id)
    navigating = true
    hl.dispatch(hl.dsp.focus({ window = target }))
    navigating = false
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

for key, dir in pairs({ LEFT = "l", RIGHT = "r", UP = "u", DOWN = "d" }) do
  local name = ({ l = "left", r = "right", u = "above", d = "below" })[dir]
  hl.unbind("SUPER + " .. key)
  o.bind("SUPER + " .. key, "Focus on " .. name .. " window", guarded(M.focus(dir)))
end

_G.omarchy_stage = M
return M
