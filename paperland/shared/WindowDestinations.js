/** Native workspace snapshots, including named/special and empty workspaces. */
function entries(monitors, workspaces) {
  var result = [];
  monitors.filter(function(m) { return !m.disabled; }).forEach(function(m) {
    workspaces.filter(function(w) { return Number.isInteger(w.id) && typeof w.name === "string" && w.monitorID === m.id; })
      .sort(function(a, b) { return a.id - b.id; }).forEach(function(w) {
        result.push({ kind: "existing", id: w.id, name: w.name, monitor: m.name, monitorId: m.id, layout: w.tiledLayout,
          selector: w.id > 0 ? String(w.id) : w.name.indexOf("special:") === 0 ? w.name : "name:" + w.name,
          label: (w.id > 0 && w.name !== String(w.id) ? w.id + " · " : "") + w.name
            + (w.windows === 0 ? " · Empty" : "") });
      });
  });
  return result;
}

/** Explicit numeric entry follows Hyprland's signed 32-bit positive ID range. */
function number(value) {
  return /^[1-9][0-9]*$/.test(value) && Number(value) <= 2147483647 ? Number(value) : 0;
}

/** Build one compositor-side validation-and-move function.
 * @param {string} stableId Native stable ID, never a title or recycled address.
 * @param {Object} destination Captured native destination or explicit number intent.
 * @param {boolean} follow Whether native focus follows the moved window.
 * @param {function(string): (string|null)} quote Existing Lua string encoder.
 * @param {number|undefined} source Required source workspace for a group send.
 * @param {string[]|undefined} required All selected native IDs checked before the first group action.
 */
function command(stableId, destination, follow, quote, source, required) {
  if (!/^[0-9a-f]+$/i.test(stableId) || !destination || typeof follow !== "boolean") return "";
  var code = 'function() local w=hl.get_window("stableid:' + stableId + '"); if not w then error("That window is no longer available.") end; ';
  if (required) {
    if (!Number.isInteger(source) || !Array.isArray(required) || required.some(function(id) { return !/^[0-9a-f]+$/i.test(id); })) return "";
    required.forEach(function(id) {
      code += 'local selected=hl.get_window("stableid:' + id + '"); '
        + 'if not selected or not selected.workspace or selected.workspace.id~=' + source
        + ' then error("The selection changed before dispatch.") end; ';
    });
  }
  if (source !== undefined) {
    if (!Number.isInteger(source)) return "";
    code += 'if not w.workspace or w.workspace.id~=' + source
      + ' then error("That window left its source Desktop.") end; ';
  }
  var selector;
  if (destination.kind === "floating") {
    if (!Number.isInteger(destination.id)) return "";
    return code + 'hl.dispatch(hl.dsp.window.float({window=w,action="set"})) end';
  }
  if (destination.kind === "existing") {
    selector = quote(destination.selector);
    var name = quote(destination.name), monitor = quote(destination.monitor);
    if (!selector || !name || !monitor || !Number.isInteger(destination.id)) return "";
    code += 'local d=hl.get_workspace(' + selector + '); if not d or d.id~=' + destination.id
      + ' or d.name~=' + name + ' or not d.monitor or d.monitor.name~=' + monitor
      + ' then error("That destination changed. Select it again.") end; ';
    // Workspace objects serialize negative IDs as relative selectors in Hyprland.
    // Keep the validated name/special selector through dispatch.
  } else if (destination.kind === "number") {
    if (!number(String(destination.id))) return "";
    selector = '"' + destination.id + '"';
  } else return "";
  return code + 'hl.dispatch(hl.dsp.window.move({window=w,workspace=' + selector + ',follow=' + follow + '})) end';
}
