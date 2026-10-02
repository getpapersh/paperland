function snapshot() {
  var monitors = [
    { id: 1, name: "DP-1", x: 0, y: 0, width: 2560, height: 1440, scale: 1.25, transform: 0, activeWorkspace: { id: 1 } },
    { id: 2, name: "HDMI-A-1", x: 2048, y: 0, width: 1920, height: 1080, scale: 1, transform: 0, activeWorkspace: { id: 3 } },
    { id: 3, name: "DP-2 Portrait", x: -1080, y: 0, width: 1920, height: 1080, scale: 1, transform: 1, activeWorkspace: { id: 5 } }
  ];
  var workspaces = [];
  var clients = [];
  var names = ["Code", "Research", "Writing", "Messages", "Reference"];
  var apps = ["code", "chromium", "foot", "org.gnome.Nautilus", "discord"];
  for (var id = 1; id <= 5; id++) {
    var monitor = monitors[id < 3 ? 0 : id < 5 ? 1 : 2];
    workspaces.push({ id: id, name: id + " · " + names[id - 1], monitorID: monitor.id, tiledLayout: "scrolling", hasfullscreen: false });
    for (var i = 0; i < 10; i++) {
      var n = (id - 1) * 10 + i + 1;
      var vertical = id === 5;
      var grouped = i === 5 || i === 6;
      clients.push({
        address: "0x" + n.toString(16),
        title: i % 3 === 0 ? "Paperland roadmap — multi-display navigation and interaction notes" + (i === 9 ? " — document 10" : "") : names[id - 1] + " — document " + (i + 1),
        class: apps[i % apps.length],
        workspace: { id: id }, monitor: monitor.id, mapped: true,
        at: [monitor.x + 20 + (vertical ? 0 : i * 720), monitor.y + 45 + (vertical ? i * 600 : 0)],
        size: vertical ? [1020, 550] : [690, 990],
        visible: i < 2, hidden: i === 6, floating: i === 8,
        pinned: i === 9 && monitor.activeWorkspace.id === id,
        fullscreen: 0, focusHistoryID: n === 21 ? 0 : n,
        grouped: grouped ? ["0x" + ((id - 1) * 10 + 6).toString(16), "0x" + ((id - 1) * 10 + 7).toString(16)] : []
      });
    }
  }
  return { monitors: monitors, workspaces: workspaces, clients: clients, directions: { global: "right", 5: "down" } };
}
