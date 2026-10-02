/** @typedef {{address:string, mapped:boolean, hidden?:boolean, grouped?:string[], class:string, title:string, focusHistoryID?:number, workspace?:{name:string}}} Client */
/** @typedef {{address:string, app:string, title:string, focusOrder:number}} ScratchpadWindow */
/** @typedef {{id:string, special:boolean, name:string, count:number, windows:ScratchpadWindow[], monitor:string, active:boolean, focused:boolean}} ScratchpadEntry */

/**
 * Keep native client order. The count includes every client assigned to the
 * special workspace; the preview list contains only clients Paperland can show.
 * @param {Client[]} clients
 * @returns {ScratchpadEntry}
 */
function build(clients) {
  var assigned = clients.filter(function(client) {
    return client.mapped === true && client.workspace && client.workspace.name === "special:scratchpad";
  });
  var windows = assigned.filter(function(client) {
    return client.class !== "org.omarchy.screensaver"
      && (!client.hidden || (client.grouped && client.grouped.length > 1));
  }).map(function(client) {
    return { address: client.address, app: client.class, title: client.title || client.class,
      focusOrder: Number.isInteger(client.focusHistoryID) ? client.focusHistoryID : -1 };
  });
  return { id: "special:scratchpad", special: true, name: "Scratchpad", count: assigned.length,
    windows: windows, monitor: "", active: false, focused: false };
}

/**
 * @param {Array<{description?:string, modmask?:number, key?:string}>} bindings
 * @returns {{modifiers:number, key:string}|null}
 */
function toggleBinding(bindings) {
  var binding = bindings.find(function(item) {
    var description = String(item.description || "").toLowerCase();
    return description.indexOf("toggle") >= 0 && description.indexOf("scratchpad") >= 0
      && description.indexOf("move") < 0;
  });
  if (!binding || !Number.isInteger(binding.modmask) || typeof binding.key !== "string" || !binding.key)
    return null;
  return { modifiers: binding.modmask, key: binding.key };
}

/** @param {{modifiers:number,key:string}|null} binding @returns {string} */
function identifier(binding) {
  return binding && binding.modifiers === 64 && binding.key.length === 1
    ? binding.key.toUpperCase() : "S";
}

/** @param {{modifiers:number,key:string}|null} binding @returns {string} */
function shortcutName(binding) {
  if (!binding) return "";
  var names = [];
  [[64, "Super"], [16, "Ctrl"], [8, "Alt"], [1, "Shift"]].forEach(function(modifier) {
    if (binding.modifiers & modifier[0]) names.push(modifier[1]);
  });
  var key = binding.key.length === 1 ? binding.key.toUpperCase() : binding.key;
  return names.concat(key).join("+");
}

/** @param {{count:number}|null} entry @param {{modifiers:number,key:string}|null} binding @returns {string} */
function accessibleName(entry, binding) {
  if (!entry) return "";
  var name = "Scratchpad, " + entry.count + (entry.count === 1 ? " window" : " windows");
  var shortcut = shortcutName(binding);
  return shortcut ? name + ", shortcut " + shortcut : name;
}

/**
 * @param {Array<{name:string,lastIpcObject?:{specialWorkspace?:{name:string}}}>} monitors
 * @param {string} name
 * @returns {boolean}
 */
function isOpenOn(monitors, name) {
  var monitor = monitors.find(function(item) { return item.name === name; });
  var active = monitor && monitor.lastIpcObject && monitor.lastIpcObject.specialWorkspace;
  return !!active && active.name === "special:scratchpad";
}

/** @param {ScratchpadEntry} entry @param {string} monitor @param {boolean} open @param {boolean} focused @returns {ScratchpadEntry} */
function forMonitor(entry, monitor, open, focused) {
  return Object.assign({}, entry, { monitor: monitor, active: open, focused: open && focused });
}

/**
 * True while the pan gesture's target row is still the one its monitor's
 * strip displays. A follow change or a special open/close mid-gesture would
 * otherwise leave queued moves and landings aimed at the wrong canvas.
 * @param {Record<string, object>} rows
 * @param {Array<number>} rowIds
 * @param {number} pendingWorkspace
 * @param {boolean} followEnabled
 * @returns {boolean}
 */
function panSelectionValid(rows, rowIds, pendingWorkspace, followEnabled) {
  var row = rows[pendingWorkspace];
  if (!row) return false;
  var displayed = rowFor(rows, rowIds, row.monitor, followEnabled);
  return !!displayed && displayed.id === pendingWorkspace;
}

/**
 * The row a display's strip shows: while following is enabled, the open
 * scratchpad row that Layout.build marked active on this monitor; otherwise,
 * or on every other display, the active desktop scrolling-workspace row.
 * @param {Record<string, object>} rows
 * @param {Array<number>} rowIds
 * @param {string} monitor
 * @param {boolean} followEnabled
 * @returns {object|null}
 */
function rowFor(rows, rowIds, monitor, followEnabled) {
  if (followEnabled) {
    for (var i = 0; i < rowIds.length; i++) {
      var followed = rows[rowIds[i]];
      if (followed && followed.active && followed.monitor === monitor
        && followed.id < 0 && followed.name === "special:scratchpad") return followed;
    }
  }
  for (var j = 0; j < rowIds.length; j++) {
    var row = rows[rowIds[j]];
    if (row && row.active && row.monitor === monitor && row.id > 0) return row;
  }
  return null;
}
