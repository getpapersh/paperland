-- Native column snapshots for the Omarchy Bar's workspace pill icons.
-- Installer-owned; setup loads it while Paperland's bar integration is on,
-- independently of the numbered focus chord. Membership comes from the
-- scrolling layout's own column identity, so pills never guess columns from
-- coordinates.

local function integer(value)
  return type(value) == "number" and value == value and value ~= math.huge
    and value ~= -math.huge and value == math.floor(value)
end

local function shell_quote(value)
  return "'" .. value:gsub("'", function() return "'\\''" end) .. "'"
end

local launcher = _G.paperland_columns_launcher
if type(launcher) ~= "string" or launcher == "" then
  local data = os.getenv("XDG_DATA_HOME")
  if not data or data == "" then
    local home = os.getenv("HOME")
    if home and home ~= "" then data = home .. "/.local/share" end
  end
  if data then launcher = data .. "/paperland/paperland" end
end

local columns_generation = type(_G.paperland_strip_columns_generation) == "string"
  and _G.paperland_strip_columns_generation or nil
local columns_sequence = columns_generation and integer(_G.paperland_strip_columns_sequence)
  and _G.paperland_strip_columns_sequence or 0
if columns_sequence < 0 then columns_sequence = 0 end
if not columns_generation then
  columns_generation = tostring(os.time()) .. ":" .. string.format("%.17g", os.clock())
end
_G.paperland_strip_columns_generation = columns_generation
_G.paperland_strip_columns_sequence = columns_sequence

local function json_quote(value)
  return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- Focus changes fire constantly; an unchanged membership is not republished
-- unless a host asked for a snapshot (it may have missed the last one).
local last_published
local function publish_columns(forced)
  if type(launcher) ~= "string" or launcher == "" then return end
  local workspaces = {}
  for _, workspace in ipairs(hl.get_workspaces()) do
    local id = workspace.id
    local monitor = workspace.monitor
    if type(id) == "number" and id > 0 and id == math.floor(id)
        and monitor and type(monitor.name) == "string" and monitor.name ~= ""
        and workspace.tiled_layout == "scrolling" then
      local columns = {}
      for _, window in ipairs(workspace:get_windows()) do
        local layout = window.layout
        if window.mapped and not window.floating and not window.pinned
            and layout and layout.name == "scrolling" and layout.column
            and integer(layout.column.index)
            and type(window.address) == "string" and window.address:match("^0x[%x]+$") then
          local index = layout.column.index
          columns[index] = columns[index] or {}
          local members = columns[index]
          members[#members + 1] = window.address
        end
      end
      -- Native column indices are zero-based and the map is sparse; collect
      -- and sort the real keys instead of counting 1..#columns, which drops
      -- column 0. Member order within a column stays native.
      local keys = {}
      for index in pairs(columns) do
        if type(columns[index]) == "table" and #columns[index] > 0 then
          keys[#keys + 1] = index
        end
      end
      table.sort(keys)
      local compact = {}
      for position, index in ipairs(keys) do
        local quoted = {}
        for _, address in ipairs(columns[index]) do
          quoted[#quoted + 1] = json_quote(address)
        end
        compact[position] = "[" .. table.concat(quoted, ",") .. "]"
      end
      workspaces[#workspaces + 1] = '{"id":' .. string.format("%d", id)
        .. ',"monitor":' .. json_quote(monitor.name)
        .. ',"columns":[' .. table.concat(compact, ",") .. "]}"
    end
  end
  local body = table.concat(workspaces, ",")
  if body == last_published and not forced then return end
  last_published = body
  columns_sequence = columns_sequence + 1
  _G.paperland_strip_columns_sequence = columns_sequence
  local payload = '{"generation":"' .. columns_generation .. '","seq":' .. columns_sequence
    .. ',"workspaces":[' .. body .. "]}"
  hl.exec_cmd(shell_quote(launcher) .. " strip-columns "
    .. shell_quote(payload) .. " >/dev/null 2>&1")
end

local columns_settle
local columns_forced = false
local function queue_columns(forced)
  columns_forced = columns_forced or forced == true
  if columns_settle then columns_settle:set_enabled(false) end
  columns_settle = hl.timer(function()
    local force = columns_forced
    columns_forced = false
    publish_columns(force)
  end, { timeout = 150, type = "oneshot" })
  columns_settle:set_enabled(true)
end

-- Paperland hosts pull a fresh snapshot after their runtime loads: publishes
-- emitted while no instance listened would otherwise be lost, so startup
-- cannot rely on events alone (the push-follow pattern shell.qml uses).
_G.paperland_strip_columns_request = function() queue_columns(true) end

for _, event in ipairs({
    "window.active", "window.open", "window.close", "window.move_to_workspace",
    "window.class", "window.fullscreen", "window.pin", "window.update_rules",
    "workspace.active", "workspace.created", "workspace.removed",
    "workspace.move_to_monitor", "workspace.special_active",
    "monitor.focused", "monitor.layout_changed",
  }) do
  hl.on(event, queue_columns)
end
queue_columns()
