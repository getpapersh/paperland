-- Native monitor rules own the scroll axis; Paperland only publishes the policy.
local options = _G.paperland_monitor_direction_options or {}
local directions = {}
local applied = {}
local desktop_rules = {}
local valid = { right = true, left = true, up = true, down = true }

local function safe_name(name)
  return type(name) == "string" and name ~= "" and name:match("^[%w_.:-]+$") ~= nil
end

local function finite_positive(value)
  return type(value) == "number" and value > 0 and value < math.huge
end

local function direction(monitor)
  if not safe_name(monitor.name) or not finite_positive(monitor.width)
      or not finite_positive(monitor.height) or not finite_positive(monitor.scale)
      or type(monitor.transform) ~= "number" or monitor.transform < 0
      or monitor.transform > 7 or monitor.transform ~= math.floor(monitor.transform) then
    return nil
  end
  local override = options.overrides and options.overrides[monitor.name]
  if valid[override] then return override end
  local width, height = monitor.width, monitor.height
  if monitor.transform % 2 == 1 then width, height = height, width end
  return height / monitor.scale > width / monitor.scale and "down" or "right"
end

local function snapshot()
  local native = hl.plugin and hl.plugin.paperland
  local native_available = native and type(native.effective_direction) == "function" or false
  local entries = {}
  for name, value in pairs(directions) do
    entries[#entries + 1] = string.format('"%s":"%s"', name, value)
  end
  table.sort(entries)
  local numbered = {}
  local registered = {}
  for number, rule in pairs(desktop_rules) do
    if rule and rule.is_enabled and rule:is_enabled() then
      registered[#registered + 1] = string.format('"%d":true', number)
    end
  end
  table.sort(registered)
  if native_available then
    for number, rule in pairs(desktop_rules) do
      if rule and rule.is_enabled and rule:is_enabled() then
        local ok, value = pcall(native.effective_direction, number)
        if not ok then
          native_available = false
          numbered = {}
          break
        end
        if valid[value] then
          numbered[#numbered + 1] = string.format('"%d":"%s"', number, value)
        end
      end
    end
  end
  table.sort(numbered)
  return '{"enabled":true,"native_direction_available":' .. tostring(native_available)
    .. ',"monitors":{' .. table.concat(entries, ",")
    .. '},"desktops":{' .. table.concat(numbered, ",")
    .. '},"registered_desktops":{' .. table.concat(registered, ",") .. '}}'
end

_G.paperland_monitor_direction_snapshot = snapshot

local function reconcile()
  local current = {}
  for _, monitor in ipairs(hl.get_monitors()) do
    local resolved = direction(monitor)
    if resolved then
      current[monitor.name] = resolved
      if applied[monitor.name] ~= resolved then
        -- Reload reconstructs Lua rules from configuration. Never disable a
        -- handle: Hyprland may have merged a foreign same-selector rule into it.
        hl.workspace_rule({ workspace = "m[" .. monitor.name .. "]",
          layout_opts = { direction = resolved } })
        applied[monitor.name] = resolved
      end
    end
  end
  directions = current
  for number, value in pairs(options.desktops or {}) do
    if type(number) == "number" and number > 0 and number == math.floor(number)
        and (value == "right" or value == "down") then
      local rule = desktop_rules[number]
      if not rule then
        rule = hl.workspace_rule({ workspace = "r[" .. number .. "-" .. number .. "]",
          layout_opts = { direction = value } })
        desktop_rules[number] = rule
      end
    end
  end
end

reconcile()
local settle
for _, event in ipairs({"monitor.added", "monitor.removed", "monitor.layout_changed"}) do
  hl.on(event, function()
    if settle then settle:set_enabled(false) end
    settle = hl.timer(reconcile, { timeout = 100, type = "oneshot" })
  end)
end
