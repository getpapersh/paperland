pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io

// The shell's only link to settings.ini. It reads the file (blocking at start, again on every
// change by any writer) and persists changes by running the shared writer, one process at a
// time and in order. Nothing here writes the file itself, so no deferred write can undo another
// writer's change.
QtObject {
  id: root
  required property string path
  required property string writer

  // Emitted with the file's text at start, after any change to it and after a failed write.
  signal changed(string text)
  signal writeFailed(string detail)

  // key -> number of queued or running writes that still have to land.
  property var pending: ({})
  property var queue: []
  property var current: null
  property bool busy: false

  // FileViewError of the latest throwaway load.
  property int freshError: 0
  property bool freshLoaded: false

  // The file's text, "" when it does not exist, null when it exists but cannot be read.
  // FileView.reload() is asynchronous and a watched view reports failures late, but a FileView with
  // blockLoading reads once waitForJob returns, so a throwaway one gives the current state now.
  function read(): var {
    freshError = 0;
    freshLoaded = false;
    var fresh = freshView.createObject(root, { path: root.path }) as FileView;
    fresh.waitForJob();
    var text = freshLoaded ? fresh.text() : (freshError === FileViewError.FileNotFound ? "" : null);
    fresh.destroy();
    return text;
  }
  // The shell's in-memory value for a pending key is newer than the file; reads must not revert it.
  function isPending(key: string): bool { return (pending[key] || 0) > 0; }
  // Rereads now instead of waiting for the file watcher. An unreadable file emits nothing, so live
  // values survive a read error.
  function refresh(): void {
    var text = read();
    if (text !== null) changed(text);
  }

  // updates: typed values (bool, int, string) the writer validates against the registry.
  function write(updates: var): void {
    var counts = Object.assign({}, pending);
    // pinned and peek are checked together; a rejected batch must not take unrelated keys with it.
    var coupled = function(entry) { return "pinned" in entry || "peek" in entry; };
    var last = queue.length ? queue[queue.length - 1] : null;
    if (last && (coupled(last) || coupled(updates))) last = null;
    var entry = last || {};
    for (var key in updates) {
      if (!(key in entry)) counts[key] = (counts[key] || 0) + 1;
      entry[key] = updates[key];
    }
    pending = counts;
    if (!last) queue.push(entry);
    pump();
  }
  function pump(): void {
    if (busy || queue.length === 0) return;
    busy = true;
    settled = false;
    current = queue.shift();
    process.command = ["python3", root.writer, "apply", JSON.stringify(current)];
    process.running = true;
  }
  // Process emits exited only for a process that started, so a failed start settles from running.
  property bool settled: true
  function finish(ok: bool): void {
    if (settled) return;
    settled = true;
    var counts = Object.assign({}, pending);
    for (var key in current) {
      if (--counts[key] <= 0) delete counts[key];
    }
    pending = counts;
    current = null;
    busy = false;
    if (!ok) {
      var detail = errorOutput.text.trim() || "settings writer failed or could not start";
      console.warn("Paperland could not save settings: " + detail);
      writeFailed(detail);
    }
    // A change by another writer that arrived while a key was pending was skipped; read it now
    // (after a failure this also restores the file's values).
    refresh();
    pump();
  }

  property FileView view: FileView {
    path: root.path
    blockLoading: true
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.changed(text())
  }
  property Component freshView: Component {
    FileView {
      blockLoading: true
      printErrors: false
      onLoaded: root.freshLoaded = true
      onLoadFailed: error => root.freshError = error
    }
  }
  property Process process: Process {
    stderr: StdioCollector { id: errorOutput }
    onExited: (code, status) => root.finish(code === 0 && status === 0)
    onRunningChanged: if (!running) root.finish(false)
  }
}
