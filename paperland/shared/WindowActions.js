/** Native Lua for the shared window menu's per-window actions.
 * Every command re-resolves the captured stable ID inside the compositor, so a
 * closed or replaced window is a no-op rather than an action on a recycled address.
 */

function lookup(stableId) {
  return 'function() local w=hl.get_window("stableid:' + stableId + '"); if not w then return end; ';
}

/** @param {string} stableId Native stable ID. @returns {string} Empty when invalid. */
function toggleFloat(stableId) {
  if (!/^[0-9a-f]+$/i.test(stableId)) return "";
  return lookup(stableId) + 'hl.dispatch(hl.dsp.window.float({window=w,action="toggle"})) end';
}

/** Adjacent monitor in left-to-right logical order, measured from the window's own
 * monitor. Hyprland's "l"/"r" selectors resolve from the focused monitor instead.
 * @param {string} stableId
 * @param {number} delta -1 for left, +1 for right.
 * @returns {string}
 */
function moveToDisplay(stableId, delta) {
  if (!/^[0-9a-f]+$/i.test(stableId) || (delta !== -1 && delta !== 1)) return "";
  return lookup(stableId) + 'if not w.monitor then return end; '
    + 'local ms=hl.get_monitors(); table.sort(ms,function(a,b) if a.x~=b.x then return a.x<b.x end return a.y<b.y end); '
    + 'local i=nil for k,m in ipairs(ms) do if m.name==w.monitor.name then i=k end end; '
    + 'if not i then return end; local t=ms[i+(' + delta + ')]; if not t then return end; '
    + 'hl.dispatch(hl.dsp.window.move({window=w,monitor=t.name,follow=false})) end';
}

/** @param {string} stableId @returns {string} */
function close(stableId) {
  if (!/^[0-9a-f]+$/i.test(stableId)) return "";
  return lookup(stableId) + 'hl.dispatch(hl.dsp.window.close({window=w})) end';
}

/** PaperMac's Quit App is a cancellable request. Close every window of the owning
 * process gracefully so apps can still prompt to save; never signal the process.
 * @param {string} stableId
 * @returns {string}
 */
function quitApp(stableId) {
  if (!/^[0-9a-f]+$/i.test(stableId)) return "";
  return lookup(stableId) + 'local pid=w.pid; if not pid or pid<=0 then hl.dispatch(hl.dsp.window.close({window=w})) return end; '
    + 'for _,o in ipairs(hl.get_windows()) do if o.pid==pid and o.mapped then hl.dispatch(hl.dsp.window.close({window=o})) end end end';
}
