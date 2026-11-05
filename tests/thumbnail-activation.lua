-- Run from the repository root: lua tests/thumbnail-activation.lua
-- Exercise the registered layout and real window.active callback together.
local function scenario(already_focused)
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
    dispatch = function(command)
      if command == "refresh" then
        recalculate()
      elseif type(command) == "table" and command.window then
        active = command.window
        events["window.active"](active, 3)
      end
    end,
    dsp = {
      layout = function(message) return message end,
      focus = function(options) return options end,
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
  active = already_focused and second or first
  env.omarchy_stage.activate(second.address)
  for _, callback in ipairs(timers) do callback() end
  local promoted = b.box.w > a.box.w
  assert(promoted, "Activation did not promote thumbnail")
  assert(active == second, "Activation did not focus thumbnail")
end

scenario(false)
scenario(true)
print("Focused and unfocused thumbnail activation passed")
