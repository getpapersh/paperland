import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "Onboarding.js" as Logic

// First-run welcome and First Flow coach. The shell owns persistence and
// what "Start Flowing" shows.
Item {
  id: root
  property var service: null
  // Bound by the shell; a flip credits the minimap lesson.
  property bool minimapVisible: false
  property bool welcomeOpen: false
  // Frozen when opened so the card does not follow later focus changes.
  property var welcomeScreen: null
  signal welcomeClosed()
  signal flowStarted()
  // The minimap lesson starts from a visible minimap.
  signal minimapShowRequested()
  function focusedScreen(): var {
    var monitor = Hyprland.focusedMonitor;
    return Quickshell.screens.find(function(screen) { return !!monitor && screen.name === monitor.name; }) || null;
  }
  function openWelcome(): void {
    // A replay restarts the tour, so an earlier run must not keep crediting.
    closeCoach();
    welcomeScreen = focusedScreen();
    welcomeOpen = true;
  }
  function closeWelcome(start: bool): void {
    if (!welcomeOpen) return;
    welcomeOpen = false;
    welcomeClosed();
    if (start) { flowStarted(); startCoach(); }
  }

  property bool coachOpen: false
  property var coachScreen: null
  property var coach: ({ index: 0, reps: 0, feedback: "", done: false })
  // "Got it" belongs to the lesson just finished, not the one it advanced to.
  readonly property var lesson: Logic.LESSONS[coach.feedback === "Got it" ? coach.index - 1 : coach.index]
  readonly property int focusedWorkspace: Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 0
  readonly property int openSpecial: {
    var monitor = Hyprland.focusedMonitor;
    var special = monitor && monitor.lastIpcObject ? monitor.lastIpcObject.specialWorkspace : null;
    return special && special.name ? special.id : 0;
  }
  // One workspace decides both readiness and which focus moves count.
  readonly property int practice: Logic.practiceWorkspace(focusedWorkspace, openSpecial)
  readonly property bool practiceVertical: !!service && !!service.rows[practice] && !!service.rows[practice].vertical
  readonly property bool otherDesktop: Hyprland.workspaces.values.some(function(workspace) {
    return workspace.id > 0 && workspace.id !== root.focusedWorkspace && !!workspace.monitor
      && !!Hyprland.focusedMonitor && workspace.monitor.name === Hyprland.focusedMonitor.name;
  })
  readonly property var cold: coachOpen && lesson.id === "scroll" && !coach.feedback && service
    ? Logic.coldStart(service.rows, service.rowIds, practice) : ({ waiting: false, jump: 0 })
  readonly property var coachKeys: Logic.lessonKeys(service ? service.bindings : [], lesson.id, practiceVertical)
  readonly property string coachInstruction: cold.waiting ? "Open another app on this Desktop to practice moving along the strip."
    : Logic.lessonInstruction(lesson, coachKeys.length > 0, otherDesktop)
  property string lastAddress: ""
  property int lastWorkspace: 0
  // A newly opened window takes focus by itself; that is not the user's move.
  property string openedAddress: ""
  function startCoach(): void {
    coach = { index: 0, reps: 0, feedback: "", done: false };
    shownLesson = "scroll";
    coachScreen = welcomeScreen || focusedScreen();
    observeFocus();
    coachOpen = true;
  }
  function closeCoach(): void { feedbackTimer.stop(); coachOpen = false; }
  function credit(event: string): void {
    if (!coachOpen) return;
    var next = Logic.coachEvent(coach, event);
    if (next === coach) return;
    coach = next;
    feedbackTimer.restart();
  }
  function skipLesson(): void {
    feedbackTimer.stop();
    coach = Logic.coachSkip(coach);
    if (coach.done) closeCoach();
  }
  function observeFocus(): void {
    var window = Hyprland.activeToplevel;
    var next = { address: window ? window.address.replace(/^0x/, "") : "",
      workspace: window && window.workspace ? window.workspace.id : 0 };
    if (Logic.focusCredit({ address: lastAddress, workspace: lastWorkspace }, next, practice, cold.waiting, openedAddress))
      credit("focus");
    if (next.address === openedAddress) openedAddress = "";
    lastAddress = next.address;
    lastWorkspace = next.workspace;
  }
  // Lesson ids, not object identity: clearing "Nice" re-evaluates `lesson`
  // and must not reveal a minimap the user just hid for that lesson.
  property string shownLesson: ""
  onLessonChanged: {
    if (!coachOpen || lesson.id === shownLesson) return;
    shownLesson = lesson.id;
    if (Logic.revealsMinimap(lesson.id)) minimapShowRequested();
  }
  onMinimapVisibleChanged: credit(minimapVisible ? "minimap-show" : "minimap-hide")
  onFocusedWorkspaceChanged: credit("workspace")
  Connections {
    target: Hyprland
    function onActiveToplevelChanged() { root.observeFocus(); }
    function onRawEvent(event) {
      if (event.name === "openwindow") root.openedAddress = event.data.split(",")[0].replace(/^0x/, "");
    }
  }
  Timer {
    id: feedbackTimer
    interval: root.coach.done ? 2000 : 1200
    onTriggered: {
      if (root.coach.done) root.closeCoach();
      else root.coach = Object.assign({}, root.coach, { feedback: "" });
    }
  }
  PanelWindow {
    screen: root.coachScreen
    visible: root.coachOpen
    anchors { top: true }
    margins { top: 48 }
    implicitWidth: coachCard.implicitWidth
    implicitHeight: coachCard.implicitHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "paperland-coach"
    WlrLayershell.layer: WlrLayer.Overlay
    // Lessons are taught with the user's own keys; the coach never takes them.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    CoachCard {
      id: coachCard
      anchors.fill: parent
      title: root.cold.waiting ? "Let's get you flowing" : root.lesson.title
      instruction: root.coachInstruction
      keys: root.cold.waiting ? [] : root.coachKeys
      position: Logic.LESSONS.indexOf(root.lesson) + 1
      total: Logic.LESSONS.length
      feedback: root.coach.feedback
      jumpLabel: root.cold.jump ? "Go to Desktop " + root.cold.jump : ""
      onSkipped: root.skipLesson()
      onClosed: root.closeCoach()
      onJumpRequested: if (root.service) root.service.activateWorkspace(root.cold.jump)
    }
  }
  PanelWindow {
    id: welcomeWindow
    // Clicked and still under the pointer.
    property bool engaged: false
    // Before Hyprland reports a monitor at startup, follow it until one exists.
    screen: root.welcomeScreen || root.focusedScreen()
    visible: root.welcomeOpen
    onVisibleChanged: engaged = false
    implicitWidth: card.implicitWidth
    implicitHeight: card.implicitHeight
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "paperland-welcome"
    WlrLayershell.layer: WlrLayer.Overlay
    // Typing stays in the user's app until the card is clicked; leaving it
    // hands the keyboard back. On Hyprland 0.56.2 an OnDemand layer takes
    // focus as soon as it maps, and switching to OnDemand later did not make
    // a click focus it.
    WlrLayershell.keyboardFocus: engaged ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    WelcomeCard {
      id: card
      anchors.fill: parent
      focus: true
      rows: Logic.shortcutRows(root.service ? root.service.bindings : [])
      onSkipped: root.closeWelcome(false)
      onStarted: root.closeWelcome(true)
      HoverHandler { onHoveredChanged: if (!hovered) welcomeWindow.engaged = false }
      TapHandler { onPressedChanged: if (pressed) welcomeWindow.engaged = true }
    }
  }
}
