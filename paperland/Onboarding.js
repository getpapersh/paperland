// Hyprland modmask bits in PaperMac's keycap order.
var MODIFIERS = [[64, "Super"], [4, "Ctrl"], [8, "Alt"], [1, "Shift"]];
var KEY_NAMES = { LEFT: "←", RIGHT: "→", UP: "↑", DOWN: "↓", grave: "`", space: "Space", Return: "Enter", Tab: "Tab" };

/** Keycap name for a Hyprland key identity. @param {string} key @returns {string} */
function keyName(key) {
  if (KEY_NAMES[key]) return KEY_NAMES[key];
  return key.length === 1 ? key.toUpperCase() : key.charAt(0).toUpperCase() + key.slice(1);
}

/**
 * Keycaps of the first binding whose description matches. Hyprland's Lua IPC
 * reports physical-code keys (digits) with an empty key, so `range` stands in
 * for them; without one such a binding is unknown rather than guessed.
 * @param {Array<{modmask?:number,key?:string,description?:string}>} bindings `hyprctl -j binds`
 * @param {string} description
 * @param {string=} range
 * @returns {string[]} empty when not bound or unknown
 */
function keycaps(bindings, description, range) {
  if (!Array.isArray(bindings)) return [];
  var binding = bindings.find(function(item) { return item && item.description === description; });
  if (!binding || !Number.isInteger(binding.modmask)) return [];
  var key = typeof binding.key === "string" && binding.key ? keyName(binding.key) : range || "";
  if (!key) return [];
  var caps = [];
  MODIFIERS.forEach(function(modifier) { if (binding.modmask & modifier[0]) caps.push(modifier[1]); });
  return caps.concat(key);
}

/**
 * Welcome "Shortcut style" rows. The minimap and overview always appear,
 * with a pointer-only route when unbound; optional integrations appear only
 * when loaded.
 * @param {Array<Object>} bindings
 * @returns {Array<{id:string,label:string,keys:string[],hint:string}>}
 */
function shortcutRows(bindings) {
  return [
    { id: "minimap", label: "Show or hide the minimap", keys: keycaps(bindings, "Paperland minimap"),
      hint: "Run paperland toggle" },
    { id: "overview", label: "Search every window", keys: keycaps(bindings, "Paperland overview"),
      hint: "Click the search icon on the minimap" },
    { id: "switcher", label: "Switch between recent windows", keys: keycaps(bindings, "Paperland window switcher"), hint: "" },
    { id: "strip", label: "Focus a window on the strip", keys: keycaps(bindings, "Paperland: focus strip window 1", "1–9"), hint: "" },
  ].filter(function(row) { return row.keys.length > 0 || row.hint !== ""; });
}

/**
 * First Flow lessons. `events` lists, per repetition, the native change that
 * credits it: "focus" (another window on the practice workspace),
 * "minimap-hide" / "minimap-show" (visibility flips, in that order, so a
 * programmatic reveal never counts) or "workspace" (focused workspace changes).
 */
var LESSONS = [
  { id: "scroll", title: "You drive the strip", events: ["focus", "focus"],
    instruction: "Press the shortcut below to move focus to the next window along the strip. Do it twice.",
    fallback: "Click another window on this Desktop to move focus along the strip. Do it twice." },
  { id: "minimap", title: "Meet the minimap", events: ["minimap-hide", "minimap-show"],
    instruction: "The minimap shows your whole canvas at a glance. Press the shortcut below to hide it, then press it again to bring it back.",
    fallback: "The minimap shows your whole canvas at a glance. Run paperland toggle to hide it, then again to bring it back." },
  { id: "desktop", title: "Slide between Desktops", events: ["workspace", "workspace"],
    instruction: "Each Desktop keeps its own strip. Press the shortcut below to switch to another Desktop, then switch back.",
    fallback: "Each Desktop keeps its own strip. Click another Desktop pill in the minimap, then click this Desktop's pill to come back.",
    // With one Desktop there is no pill to click; + opens a new one, which
    // Hyprland removes again once it is left empty.
    single: "Each Desktop keeps its own strip. Click + in the minimap to open a new Desktop, then click this Desktop's pill to come back." },
];

/**
 * Lessons that start with the minimap shown: the minimap lesson hides and
 * shows it, and the Desktop lesson's pointer route uses its pills and +.
 * Without this, hiding it and then choosing Skip would strand that route.
 * @param {string} id @returns {boolean}
 */
function revealsMinimap(id) {
  return id === "minimap" || id === "desktop";
}

/**
 * Keycaps teaching one lesson. The strip lesson follows the practice row's
 * axis: a portrait (vertical) strip is driven with up/down, not left/right.
 * @param {Array<Object>} bindings @param {string} id @param {boolean=} vertical
 * @returns {string[]}
 */
function lessonKeys(bindings, id, vertical) {
  if (id === "minimap") return keycaps(bindings, "Paperland minimap");
  if (id === "desktop") return keycaps(bindings, "Switch to workspace 1", "1–9");
  var back = keycaps(bindings, vertical ? "Focus on above window" : "Focus on left window");
  var next = keycaps(bindings, vertical ? "Focus on below window" : "Focus on right window");
  if (back.length && next.length && back.slice(0, -1).join() === next.slice(0, -1).join())
    return next.slice(0, -1).concat(back[back.length - 1] + " " + next[next.length - 1]);
  return next.length ? next : back;
}

/**
 * Instruction for the displayed lesson.
 * @param {{instruction:string,fallback:string,single?:string}} lesson
 * @param {boolean} hasKeys @param {boolean} otherDesktop another Desktop exists on this display
 * @returns {string}
 */
function lessonInstruction(lesson, hasKeys, otherDesktop) {
  if (hasKeys) return lesson.instruction;
  return lesson.single && !otherDesktop ? lesson.single : lesson.fallback;
}

/**
 * Coach state after a native event. Feedback follows PaperMac: "Nice" for a
 * repetition, "Got it" for a finished lesson, "You're flowing!" at the end.
 * While "Got it" shows, the next lesson is not on screen yet, so its events
 * are not credited.
 * @param {{index:number,reps:number,feedback:string,done:boolean}} state
 * @param {string} event
 * @returns {{index:number,reps:number,feedback:string,done:boolean}}
 */
function coachEvent(state, event) {
  var lesson = LESSONS[state.index];
  if (state.done || !lesson || state.feedback === "Got it" || event !== lesson.events[state.reps]) return state;
  var reps = state.reps + 1;
  if (reps < lesson.events.length) return { index: state.index, reps: reps, feedback: "Nice", done: false };
  if (state.index + 1 >= LESSONS.length) return { index: state.index, reps: reps, feedback: "You're flowing!", done: true };
  return { index: state.index + 1, reps: 0, feedback: "Got it", done: false };
}

/**
 * Skip the displayed lesson without feedback. During "Got it" the displayed
 * lesson is already finished; Skip only reveals the next one.
 */
function coachSkip(state) {
  if (state.done) return state;
  if (state.feedback === "Got it") return { index: state.index, reps: 0, feedback: "", done: false };
  return state.index + 1 >= LESSONS.length ? { index: state.index, reps: 0, feedback: "", done: true }
    : { index: state.index + 1, reps: 0, feedback: "", done: false };
}

/**
 * The workspace the strip lesson practises on: the special workspace open on
 * the focused display, since Hyprland keeps reporting the desktop as focused
 * while a special is shown, otherwise the focused desktop.
 * @param {number} focused focused workspace id @param {number} special open special id, 0 when none
 * @returns {number}
 */
function practiceWorkspace(focused, special) {
  return special ? special : focused;
}

/**
 * Whether a focus change is a strip-lesson repetition: both windows on the
 * practice workspace, while the lesson is not waiting for windows, and not a
 * newly opened window taking focus by itself.
 * @param {{address:string,workspace:number}} previous @param {{address:string,workspace:number}} next
 * @param {number} practice @param {boolean} waiting @param {string} opened
 * @returns {boolean}
 */
function focusCredit(previous, next, practice, waiting, opened) {
  return !waiting && !!previous.address && !!next.address && previous.address !== next.address
    && next.address !== opened && previous.workspace === practice && next.workspace === practice;
}

/**
 * Cold start for the strip lesson: it needs two windows on the practice
 * workspace. Offers the first other Desktop that has them.
 * @param {Object<string,{windows:Array}>} rows
 * @param {number[]} rowIds
 * @param {number} practice practice workspace id
 * @returns {{waiting:boolean,jump:number}} jump is 0 when there is nowhere to go
 */
function coldStart(rows, rowIds, practice) {
  var row = rows ? rows[practice] : null;
  if (row && row.windows.length >= 2) return { waiting: false, jump: 0 };
  var jump = (rowIds || []).find(function(id) { return id !== practice && id > 0 && rows[id] && rows[id].windows.length >= 2; });
  return { waiting: true, jump: jump || 0 };
}
