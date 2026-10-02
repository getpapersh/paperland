import QtQuick

// Card body for the workspace switch confirmation, with PaperMac's
// DesktopSwitchOverlay type sizes and fade/hold timing. Purely passive.
Item {
  id: root
  property real maxWidth: 560
  property string headline: ""
  property string subtitle: ""
  property bool shown: false
  readonly property int fadeInMs: 120
  readonly property int holdMs: 900
  readonly property int fadeOutMs: 450
  // True while the card is showing or still fading out, so the host window
  // stays mapped until the fade finishes.
  readonly property bool active: shown || card.opacity > 0
  implicitWidth: card.width
  implicitHeight: card.height

  // A newer switch replaces the text and restarts the hold; a card still
  // fading in or out continues from its current opacity rather than flashing.
  function show(headline: string, subtitle: string): void {
    root.headline = headline;
    root.subtitle = subtitle;
    shown = true;
    hold.restart();
  }
  function hide(): void {
    hold.stop();
    shown = false;
  }

  TextMetrics { id: titleMetrics; font: title.font; text: root.headline }
  TextMetrics { id: detailMetrics; font: detail.font; text: root.subtitle }
  Timer { id: hold; interval: root.fadeInMs + root.holdMs; onTriggered: root.shown = false }

  Rectangle {
    id: card
    readonly property real padX: 24
    // Measured apart from the eliding Text items, whose implicit width
    // follows their assigned width and would loop through this binding.
    width: Math.min(root.maxWidth, Math.ceil(Math.max(titleMetrics.advanceWidth,
      root.subtitle ? detailMetrics.advanceWidth : 0)) + 2 * padX)
    height: column.implicitHeight + 32
    radius: 18
    color: Theme.switchCardSurface
    border.color: Theme.borderStrong
    border.width: 1
    opacity: root.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: root.shown ? root.fadeInMs : root.fadeOutMs } }
    Column {
      id: column
      anchors.centerIn: parent
      width: card.width - 2 * card.padX
      spacing: 3
      Text {
        id: title
        objectName: "headline"
        width: parent.width
        text: root.headline
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        font.family: Theme.fontFamily
        font.pixelSize: 30
        font.weight: Font.DemiBold
        color: Theme.textPrimary
      }
      Text {
        id: detail
        objectName: "subtitle"
        width: parent.width
        visible: text !== ""
        text: root.subtitle
        textFormat: Text.PlainText
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        font.family: Theme.fontFamily
        font.pixelSize: 13
        font.weight: Font.Medium
        color: Theme.textSecondary
      }
    }
  }
}
