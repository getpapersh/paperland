import QtQuick

// Visibility state for one display; the owning strip decides how revealed is rendered.
Item {
    id: root

    property bool pinned: false
    property bool initiallyHidden: false
    property bool _initialized: false
    property bool held: false
    property bool suspended: false
    property int delayMs: 3000
    // One value per display refresh: { token, suppress }. Keeping both in a
    // single value removes any dependence on binding evaluation order.
    property var navigation: null
    property bool peek: true
    property bool revealed: false

    property string _lastNavigation: ""
    property bool _navigationSeen: false

    Component.onCompleted: { _initialized = true; if (pinned && !initiallyHidden) show() }

    Timer {
        id: dismissTimer
        interval: root.delayMs
        repeat: false
        onTriggered: root.revealed = false
    }

    function _armTimer() {
        if (root.revealed && root.peek && !root.pinned && !root.held && !root.suspended) {
            dismissTimer.restart()
        } else {
            dismissTimer.stop()
        }
    }

    function show() {
        root.revealed = true
        root._armTimer()
    }

    function hide() {
        dismissTimer.stop()
        root.revealed = false
    }

    onPinnedChanged: {
        if (root.pinned && root._initialized)
            root.show()
        else
            root._armTimer()
    }

    onPeekChanged: root._armTimer()
    onHeldChanged: root._armTimer()
    onSuspendedChanged: root._armTimer()
    onDelayMsChanged: root._armTimer()

    onNavigationChanged: {
        var next = root.navigation && root.navigation.token ? String(root.navigation.token) : ""
        if (next.length === 0)
            return

        if (!root._navigationSeen) {
            root._navigationSeen = true
            root._lastNavigation = next
            return
        }

        if (next === root._lastNavigation)
            return

        root._lastNavigation = next
        if (!root.pinned && root.peek && !(root.navigation && root.navigation.suppress))
            root.show()
    }

    onRevealedChanged: {
        root._armTimer()
    }
}
