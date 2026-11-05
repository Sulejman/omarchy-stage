-- Run from the repository root: lua tests/stage-focus.lua
-- Exercise the registered layout and real window.active callback together.
local function scenario(version, reason, promotes, label)
  local events, timers, layout = {}, {}, nil
  local ws = { id = 1, name = "1", tiled_layout = "lua:stage" }
  local first = { stable_id = 1, address = "0x1", mapped = true, workspace = ws, tags = {} }
  local second = { stable_id = 2, address = "0x2", mapped = true, workspace = ws, tags = {} }
  local active, windows = first, { first }
  local function target(window)
    return { window = window, place = function(self, box) self.box = box end }
  end
  local a, b = target(first), target(second)
  local ctx = { area = { x = 0, y = 0, w = 1920, h = 1080 }, targets = { a } }
  local function recalculate() layout.recalculate(ctx) end
  local hl = {
    version = function() return version end,
    layout = { register = function(_, callbacks) layout = callbacks end },
    on = function(name, callback) events[name] = callback end,
    timer = function(callback, options)
      if options.timeout == 1 then timers[#timers + 1] = callback end
    end,
    get_active_window = function() return active end,
    get_active_workspace = function() return ws end,
    get_workspace_windows = function() return windows end,
    get_config = function() return {} end,
    workspace_rule = function() end,
    unbind = function() end,
    dispatch = function(command) if command == "refresh" then recalculate() end end,
    dsp = {
      layout = function(message) return message end,
      window = { tag = function() end, set_prop = function() end },
    },
  }
  local env = setmetatable({
    hl = hl, o = { window = function() end, bind = function() end },
    -- Isolate persisted user state and the optional native plugin.
    io = { open = function() return nil end }, stage_runtime = true,
  }, { __index = _G })
  env._G = env
  assert(loadfile("hypr/stage.lua", "t", env))()
  recalculate()
  windows, ctx.targets = { first, second }, { a, b }
  recalculate()
  active = second
  events["window.active"](second, reason)
  for _, callback in ipairs(timers) do callback() end
  local promoted = b.box.w > a.box.w
  assert(promoted == promotes, version .. " " .. label .. ": expected promotion=" .. tostring(promotes))
end

local cases = {
  { "0.56.0", 16, true, "new window" },
  { "0.56.0", 5, true, "click" },
  { "0.56.0", 3, true, "focus dispatcher" },
  { "0.56.0", 8, true, "soft switch" },
  { "0.56.0", 9, true, "hard switch" },
  { "0.56.0", 1, false, "hover" },
  { "0.56.0", 2, false, "directional focus" },
  { "0.56.0", 13, false, "close fallback" },
  { "0.57.1", 1 << 16, true, "new window" },
  { "0.57.1", 1 << 4, true, "click" },
  { "0.57.1", (1 << 5) | (1 << 4), true, "click down" },
  { "0.57.1", (1 << 6) | (1 << 4), true, "click up" },
  { "0.57.1", 1 << 2, true, "focus dispatcher" },
  { "0.57.1", 1 << 8, true, "soft switch" },
  { "0.57.1", 1 << 9, true, "hard switch" },
  { "0.57.1", 1, false, "hover" },
  { "0.57.1", 2, false, "directional focus" },
  { "0.57.1", 1 << 3, false, "move into group" },
  { "0.57.1", 1 << 13, false, "close fallback" },
  { "0.58.0-dev", 1 << 16, true, "new window" },
}
local failures = 0
for _, case in ipairs(cases) do
  local ok, err = pcall(scenario, table.unpack(case))
  if not ok then failures = failures + 1; io.stderr:write(err, "\n") end
end
assert(failures == 0, failures .. " focus scenarios failed")
print(#cases .. " focus scenarios passed")
