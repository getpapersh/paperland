-- Numbered focus for the active scrolling workspace. Installer-owned; change
-- the fixed chord through `paperland setup`.

local chord = _G.paperland_strip_chord
if not chord then return end

local function integer(value)
  return type(value) == "number" and value == value and value ~= math.huge
    and value ~= -math.huge and value == math.floor(value)
end

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function rectangle(window)
  local at, size = window.at, window.size
  if not at or not size or not finite(at.x) or not finite(at.y)
      or not finite(size.x) or not finite(size.y)
      or size.x <= 0 or size.y <= 0 then return nil end
  return { x = at.x, y = at.y, right = at.x + size.x, bottom = at.y + size.y }
end

local function eligible(window)
  if not window.mapped or window.class == "org.omarchy.screensaver"
      or window.floating or window.pinned then return false end
  if window.hidden and not (window.group and window.group.size > 1) then return false end
  local layout = window.layout
  return layout and layout.name == "scrolling" and layout.column
    and integer(layout.column.index) and integer(layout.index_in_column)
end

local function add_to_column(columns, window, rect, order)
  local index = window.layout.column.index
  local column = columns[index]
  if not column then
    column = { index = index, first_order = order, windows = {},
      left = rect.x, top = rect.y, right = rect.right, bottom = rect.bottom }
    columns[index] = column
  else
    column.left = math.min(column.left, rect.x)
    column.top = math.min(column.top, rect.y)
    column.right = math.max(column.right, rect.right)
    column.bottom = math.max(column.bottom, rect.bottom)
  end
  column.windows[#column.windows + 1] = {
    address = window.address, rect = rect,
    index_in_column = window.layout.index_in_column, order = order,
  }
end

local function overlap_pairs(items, axis, boxes)
  local separated = 0
  local low, high = axis == "x" and "left" or "top", axis == "x" and "right" or "bottom"
  for i = 1, #items - 1 do
    for j = i + 1, #items do
      local a, b = boxes(items[i]), boxes(items[j])
      if a[high] <= b[low] or b[high] <= a[low] then separated = separated + 1 end
    end
  end
  return separated
end

local function sort_windows(windows, axis)
  table.sort(windows, function(a, b)
    local a_position, b_position = axis == "x" and a.rect.x or a.rect.y,
      axis == "x" and b.rect.x or b.rect.y
    if a_position ~= b_position then return a_position < b_position end
    if a.index_in_column ~= b.index_in_column then
      return a.index_in_column < b.index_in_column
    end
    return a.order < b.order
  end)
end

local function ordered_windows(workspace)
  local columns, column_list = {}, {}
  for order, window in ipairs(workspace:get_windows()) do
    if eligible(window) then
      local rect = rectangle(window)
      if rect then
        local was_new = columns[window.layout.column.index] == nil
        add_to_column(columns, window, rect, order)
        if was_new then column_list[#column_list + 1] = columns[window.layout.column.index] end
      end
    end
  end

  if #column_list == 0 then return {} end
  local column_axis = "x"
  if #column_list > 1 and overlap_pairs(column_list, "y", function(column) return column end)
      > overlap_pairs(column_list, "x", function(column) return column end) then
    column_axis = "y"
  end
  local stack_axis = column_axis == "x" and "y" or "x"
  local ordered = {}
  if #column_list > 1 then
    table.sort(column_list, function(a, b)
      local a_position = column_axis == "x" and a.left or a.top
      local b_position = column_axis == "x" and b.left or b.top
      if a_position ~= b_position then return a_position < b_position end
      if a.index ~= b.index then return a.index < b.index end
      return a.first_order < b.first_order
    end)
    for _, column in ipairs(column_list) do
      sort_windows(column.windows, stack_axis)
      for _, window in ipairs(column.windows) do ordered[#ordered + 1] = window end
    end
  else
    local windows = column_list[1].windows
    local axis = "x"
    if #windows > 1 and overlap_pairs(windows, "y", function(window) return {
        left = window.rect.x, right = window.rect.right,
        top = window.rect.y, bottom = window.rect.bottom,
      } end) > overlap_pairs(windows, "x", function(window) return {
        left = window.rect.x, right = window.rect.right,
        top = window.rect.y, bottom = window.rect.bottom,
      } end) then axis = "y" end
    sort_windows(windows, axis)
    ordered = windows
  end
  return ordered
end

-- Paperland pushes its persisted preference through the dispatch path on
-- startup and on every change. Until its first push, nil uses the preference's
-- default (on); Hyprland keeps the last pushed value if Paperland exits. Only
-- the shared scratchpad qualifies; other specials fall through to desktop.
local function strip_workspace()
  local workspace = hl.get_active_workspace()
  if not workspace then return end
  local special = hl.get_active_special_workspace()
  if _G.paperland_strip_follow ~= false and special
      and (special.name == "special:scratchpad" or special.name == "scratchpad")
      and special.tiled_layout == "scrolling" then
    return special
  end
  if workspace.special then
    workspace = workspace.monitor and workspace.monitor.active_workspace
  end
  if not workspace or workspace.tiled_layout ~= "scrolling" then return nil end
  return workspace
end

local function shell_quote(value)
  return "'" .. value:gsub("'", function() return "'\\''" end) .. "'"
end

local launcher = _G.paperland_strip_launcher
if type(launcher) ~= "string" or launcher == "" then
  -- Existing generated setup files may predate the launcher global.
  local data = os.getenv("XDG_DATA_HOME")
  if not data or data == "" then
    local home = os.getenv("HOME")
    if home and home ~= "" then data = home .. "/.local/share" end
  end
  if data then launcher = data .. "/paperland/paperland" end
end

local showing_badges = false
local pressed = {}
local suppressed = false
local badgesHeld = false
local generation = type(_G.paperland_strip_badge_generation) == "string"
  and _G.paperland_strip_badge_generation or nil
local sequence = generation and integer(_G.paperland_strip_badge_sequence)
  and _G.paperland_strip_badge_sequence or 0
if sequence < 0 then sequence = 0 end
if not generation then generation = tostring(os.time()) .. ":" .. string.format("%.17g", os.clock()) end
_G.paperland_strip_badge_generation = generation
_G.paperland_strip_badge_sequence = sequence
local function publish_badges(windows, clear)
  if type(launcher) ~= "string" or launcher == "" then return end
  local ordered = {}
  for index = 1, math.min(#windows, 9) do
    local window = windows[index]
    local address = window.address
    if type(address) == "string" and address:match("^0x[%x]+$") then
      local rect = window.rect
      ordered[#ordered + 1] = string.format('["%s",[%.17g,%.17g,%.17g,%.17g]]', address,
        rect.x, rect.y, rect.right - rect.x, rect.bottom - rect.y)
    end
  end
  sequence = sequence + 1
  _G.paperland_strip_badge_sequence = sequence
  local payload = '{"generation":"' .. generation .. '","seq":' .. sequence .. ',"windows":'
    .. (#ordered > 0 and ("[" .. table.concat(ordered, ",") .. "]")
      or (clear and "null" or "[]")) .. "}"
  local command = shell_quote(launcher) .. " strip-badges "
    .. shell_quote(payload) .. " >/dev/null 2>&1"
  hl.exec_cmd(command)
  showing_badges = #ordered > 0
end

local function show_badges()
  local workspace = strip_workspace()
  if workspace then publish_badges(ordered_windows(workspace)) end
end

local function hide_badges(force)
  if force or showing_badges then publish_badges({}, true) end
end

local badgeHeartbeat = hl.timer(function()
  if badgesHeld and not suppressed then show_badges() end
end, { timeout = 1000, type = "repeat" })
badgeHeartbeat:set_enabled(false)

local badgeSettle

local function focus_number(number)
  local workspace = strip_workspace()
  if not workspace then return end
  local windows = ordered_windows(workspace)
  local target = windows[number]
  if target then
    hl.dispatch(hl.dsp.focus({ window = "address:" .. target.address }))
    if badgesHeld and not suppressed then
      show_badges()
      if badgeSettle then badgeSettle:set_enabled(false) end
      badgeSettle = hl.timer(function()
        if badgesHeld and not suppressed then show_badges() end
      end, { timeout = 200, type = "oneshot" })
    end
  end
end

-- 0.56.2 has no per-window geometry event; the heartbeat catches in-place resizes.
for _, event in ipairs({
    "window.active", "window.open", "window.close", "window.move_to_workspace",
    "window.class", "window.fullscreen", "window.pin", "window.update_rules",
    "workspace.active", "workspace.created", "workspace.removed",
    "workspace.move_to_monitor", "workspace.special_active",
    "monitor.focused", "monitor.layout_changed",
  }) do
  hl.on(event, function()
    if badgesHeld and not suppressed then show_badges() end
  end)
end

local function held(codes)
  for _, code in ipairs(codes) do if pressed[code] then return true end end
  return false
end

-- `input.keyboard.key` reports XKB keycodes; track both physical sides of each modifier.
hl.on("input.keyboard.key", function(code, _, state)
  if state ~= 0 and state ~= 1 then return end
  local is_modifier = code == 37 or code == 105 or code == 133 or code == 134
    or code == 64 or code == 108 or code == 50 or code == 62
  if is_modifier then pressed[code] = state == 1 end

  local has_chord_modifier = held({37, 105, 133, 134})
  local chord = held({133, 134}) and held({37, 105})
  local extra = held({64, 108, 50, 62})
  chord = chord and not extra
  if has_chord_modifier and extra then suppressed = true end
  local chord_digit = not is_modifier and code >= 10 and code <= 18
  if state == 1 and has_chord_modifier and not (chord and chord_digit) and not is_modifier then
    suppressed = true
  end

  if not has_chord_modifier then suppressed = false end
  local should_show = chord and not suppressed
  if should_show then
    if not badgesHeld then
      badgesHeld = true
      badgeHeartbeat:set_enabled(true)
      show_badges()
    elseif is_modifier and state == 1 then show_badges() end
  elseif badgesHeld then
    badgesHeld = false
    badgeHeartbeat:set_enabled(false)
    if badgeSettle then badgeSettle:set_enabled(false) end
    hide_badges(true)
  else
    hide_badges()
  end
end)

for digit = 1, 9 do
  local number = digit
  local key = chord .. " + code:" .. (number + 9)
  hl.unbind(key)
  hl.bind(key, function() focus_number(number) end,
    { description = "Paperland: focus strip window " .. number })
end
