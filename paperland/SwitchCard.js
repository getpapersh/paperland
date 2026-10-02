/** @typedef {{ id: number, name: string, special: boolean }} DisplayState */
/** @typedef {{ kind: "show", monitor: string, headline: string, subtitle: string } | { kind: "hide", monitor: string }} CardAction */

/** Each enabled display's active workspace from `hyprctl -j monitors` records.
 * @param {Array<{name?:string, disabled?:boolean, activeWorkspace?:{id:number,name:string}, specialWorkspace?:{name?:string}}>} monitors
 * @returns {Object<string, DisplayState>}
 */
function displays(monitors) {
  var states = {};
  monitors.forEach(function(m) {
    if (!m || !m.name || m.disabled || !m.activeWorkspace || !Number.isInteger(m.activeWorkspace.id)) return;
    states[m.name] = { id: m.activeWorkspace.id, name: String(m.activeWorkspace.name || ""),
      special: !!(m.specialWorkspace && m.specialWorkspace.name) };
  });
  return states;
}

/** Card text: a custom name is the headline over "Workspace N"; otherwise the bare ID.
 * @param {number} id
 * @param {string} name
 * @returns {{ headline: string, subtitle: string }}
 */
function content(id, name) {
  var custom = name && name !== String(id) ? name : "";
  return custom ? { headline: custom, subtitle: "Workspace " + id } : { headline: String(id), subtitle: "" };
}

/** Diff each display's settled workspace against the last one it showed, so a
 * card lands on the display that changed rather than the focused one. A
 * display without a baseline seeds silently: neither startup nor a display
 * appearing is a switch, and Quickshell fills monitor snapshots one at a
 * time, so the first snapshot can lack displays that already exist. A special
 * workspace hides the card but keeps the baseline, since the regular
 * workspace underneath has not changed and closing the special is no switch.
 * @param {Object<string, number>} baseline last workspace ID per display
 * @param {Object<string, DisplayState>} current
 * @returns {{ baseline: Object<string, number>, actions: CardAction[] }}
 */
function plan(baseline, current) {
  var next = {}, actions = [];
  Object.keys(current).forEach(function(monitor) {
    var state = current[monitor];
    var prior = baseline[monitor];
    // Hyprland gives regular named workspaces IDs at or below -1337. Paperland
    // projects only positive IDs, so they get no card, but the display keeps
    // a baseline: returning to a numbered workspace is still a switch.
    if (!(state.id > 0)) {
      actions.push({ kind: "hide", monitor: monitor });
      next[monitor] = state.id;
      return;
    }
    if (state.special) {
      actions.push({ kind: "hide", monitor: monitor });
      next[monitor] = prior !== undefined ? prior : state.id;
      return;
    }
    next[monitor] = state.id;
    if (prior !== undefined && prior !== state.id) {
      var text = content(state.id, state.name);
      actions.push({ kind: "show", monitor: monitor, headline: text.headline, subtitle: text.subtitle });
    }
  });
  return { baseline: next, actions: actions };
}
