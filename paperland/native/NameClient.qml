import QtQuick
import Quickshell.Io

QtObject {
  id: root
  property string executable: Qt.resolvedUrl("../paperland").toString().replace(/^file:\/\//, "")
  property var capture: null
  property string requestId: ""
  property bool busy: false
  property string message: ""
  property var outcome: null
  property bool outcomeUnresolved: false
  property string commandKind: ""
  property string output: ""
  property string stderrOutput: ""
  property int polls: 0
  property int captureToken: 0
  signal captured(var value, int token)
  function run(kind, args) {
    commandKind = kind; output = ""; stderrOutput = "";
    process.command = [executable, "names", kind].concat(args);
    process.running = true;
  }
  function begin(id) {
    if (busy) { message = "A name operation is still running. Wait for its result before editing another workspace."; return 0; }
    captureToken++;
    capture = null; requestId = ""; outcome = null; outcomeUnresolved = false; busy = true;
    message = "Reading the native workspace and saved default…";
    run("begin", [String(id)]);
    return captureToken;
  }
  function submit(name, draftCapture) {
    if (busy || !draftCapture || draftCapture !== capture) return false;
    busy = true; message = "Submitting name…";
    run("submit", [JSON.stringify({ capture: draftCapture, name: name })]);
    return true;
  }
  function fail(text) { message = text; busy = false; poll.stop(); if (commandKind !== "begin") capture = null; }
  function receive(code) {
    var response;
    try { response = JSON.parse(output.trim()); }
    catch (error) { outcomeUnresolved = commandKind === "submit" || !!requestId; fail(commandKind === "submit" || requestId ? "Outcome unresolved: the writer may have accepted the change. Reload and check the live and saved names before trying again." : "Paperland’s name writer is unavailable. " + (output.trim() || stderrOutput.trim())); return; }
    if (code !== 0 || response.ok === false) { fail(response.message || "Name operation failed."); return; }
    if (commandKind === "begin") {
      capture = response.capture; busy = false;
      message = response.savedName === null || response.savedName === undefined ? "No Paperland creation default is saved." : "Saved creation default: " + response.savedName;
      captured(capture, captureToken);
    } else if (commandKind === "submit") {
      requestId = response.requestId; polls = 0; message = "Name operation queued…"; poll.restart();
    } else {
      outcome = response; outcomeUnresolved = response.state === "unresolved";
      message = (outcomeUnresolved ? "Outcome unresolved: " : "") + (response.message || response.state);
      if (response.terminal) { busy = false; capture = null; }
      else if (++polls >= 60) { outcomeUnresolved = true; fail("Outcome unresolved: the operation is taking longer than expected. Closing this editor does not cancel it."); }
      else poll.restart();
    }
  }
  property Process process: Process {
    stdout: StdioCollector { onStreamFinished: root.output = text }
    stderr: StdioCollector { onStreamFinished: root.stderrOutput = text }
    onExited: function(code) { root.receive(code); }
  }
  property Timer poll: Timer { interval: 250; onTriggered: root.run("status", [root.requestId]) }
}
