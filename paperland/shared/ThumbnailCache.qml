import QtQuick

QtObject {
  id: root
  // Each record binds an address to the actual native handle's lifetime.
  property var windows: []
  property var records: ({})
  property int generation: 0
  property var pending: null
  property double lastStart: 0
  readonly property int maxEntries: 32
  readonly property int maxEdge: 512
  onWindowsChanged: reconcile()

  function reconcile(): void {
    var next = {};
    windows.forEach(function(window) {
      if (!window.handle) return;
      var previous = root.records[window.address];
      next[window.address] = previous && previous.handle === window.handle ? previous
        : {handle: window.handle, generation: ++root.generation, result: null, capturedAt: 0, lastAttempt: 0, requestedAt: 0};
    });
    if (pending && next[pending.address] !== pending.record) cancel(pending);
    records = next;
  }

  function entry(address: string, handle: var): var {
    var record = records[address];
    return record && record.handle === handle && handle && record.result ? record : null;
  }

  function begin(address: string, handle: var, width: int, height: int): var {
    var record = records[address];
    var now = Date.now();
    if (!handle || !record || record.handle !== handle
        || width < 1 || height < 1 || width > maxEdge || height > maxEdge) return null;
    record.requestedAt = now;
    if (pending || now - lastStart < 250 || now - record.lastAttempt < 1000) return null;
    // Recently polling visible cards take turns; fixed timer order must not
    // starve later cards when more than four previews share the host.
    var older = Object.keys(records).some(function(key) {
      var candidate = root.records[key];
      return now - candidate.requestedAt < 500 && candidate.lastAttempt < record.lastAttempt;
    });
    if (older) return null;
    record.lastAttempt = now;
    lastStart = now;
    pending = {address: address, record: record, generation: record.generation, capturedAt: now};
    return pending;
  }

  function cancel(token: var): void {
    // A callback belonging to an old producer must not release a newer job.
    if (pending === token) pending = null;
  }

  function finish(token: var, result: var): bool {
    if (!token || pending !== token) return false;
    pending = null;
    var record = records[token.address];
    if (!record || record !== token.record || !record.handle
        || record.generation !== token.generation || !result || !result.url.toString()) return false;
    var next = Object.assign({}, records);
    // Consumers bind through entry(). Replacing only the outer map would keep
    // that result identical and leave their image/timestamp bindings stale.
    next[token.address] = Object.assign({}, record, {result: result, capturedAt: token.capturedAt});
    var retained = Object.keys(next).filter(function(key) { return !!next[key].result; });
    retained.sort(function(a, b) { return next[a].capturedAt - next[b].capturedAt; });
    while (retained.length > maxEntries) {
      var key = retained.shift();
      next[key] = Object.assign({}, next[key], {result: null});
    }
    records = next;
    return true;
  }

  function invalidate(address: string, handle: var): void {
    var record = records[address];
    if (!record || record.handle !== handle) return;
    if (pending && pending.record === record) cancel(pending);
    var next = Object.assign({}, records);
    next[address] = Object.assign({}, record, {generation: ++generation, result: null});
    records = next;
  }
}
