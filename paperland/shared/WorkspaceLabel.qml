import QtQuick
import "WorkspaceCatalog.js" as Catalog
import "Scratchpad.js" as Scratchpad

Item {
  id: root
  property var entry: null
  property var shortcutBinding: null
  property color foreground: "#dddddd"
  property real fontSize: 13
  property string fontFamily: "sans-serif"
  property real maximumWidth: 180
  property bool showCount: true
  property bool specialName: false
  // Shared name-part switch for the configurable pills: false hides every
  // name, including a special workspace's identity. Default true keeps the
  // inherited label for every existing consumer.
  property bool showName: true
  // Configurable-pill parts. A hidden identifier keeps the cap-height box and
  // the count's raised baseline but reserves no width; an empty title is absent.
  property bool showId: true
  property string title: ""
  readonly property string customName: {
    if (!showName) return "";
    if (Catalog.isSpecial(entry) && !specialName) return "";
    var observed = Catalog.customName(entry);
    if (!observed && specialName && entry && entry.special) return entry.name;
    return observed;
  }
  readonly property string accessibleName: scratchpad
    ? Scratchpad.accessibleName(entry, shortcutBinding) : Catalog.accessibleName(entry)
  readonly property bool special: Catalog.isSpecial(entry)
  readonly property bool scratchpad: !!entry && (entry.special === true || entry.id === "special:scratchpad")
  readonly property int nameGap: Math.round(fontSize * 0.35)
  readonly property real capHeight: Math.ceil(numberMetrics.tightBoundingRect.height)
  readonly property real identifierRight: !showId ? 0 : count.text
    ? Math.ceil(identifierMetrics.tightBoundingRect.x + identifierMetrics.tightBoundingRect.width)
    : number.implicitWidth
  readonly property real countRight: count.x + count.implicitWidth
  // Each visible part after the first is preceded by one name gap.
  readonly property real nameStart: countRight > 0 && customName ? countRight + nameGap : countRight
  readonly property real nameEnd: customName ? nameStart + nameMetrics.advanceWidth : countRight
  readonly property real titleStart: nameEnd > 0 && title ? nameEnd + nameGap : nameEnd
  width: implicitWidth
  implicitWidth: Math.min(maximumWidth, title ? titleStart + titleMetrics.advanceWidth : nameEnd)
  implicitHeight: capHeight
  TextMetrics { id: numberMetrics; font: number.font; text: "0" }
  TextMetrics { id: identifierMetrics; font: number.font; text: number.text }
  TextMetrics { id: countMetrics; font: count.font; text: count.text }
  TextMetrics { id: nameMetrics; font: name.font; text: root.customName }
  TextMetrics { id: titleMetrics; font: titleText.font; text: root.title }
  Text {
    id: number
    objectName: "workspace-label-symbol-text"
    x: 0
    y: root.height - baselineOffset
    text: root.entry ? root.special ? Scratchpad.identifier(root.shortcutBinding) : String(root.entry.id) : ""
    // Hidden but still laid out: it carries the shared baseline.
    visible: root.showId
    color: root.foreground
    font { family: root.fontFamily; pixelSize: root.fontSize; bold: true }
  }
  Text {
    id: count
    objectName: "workspace-label-count"
    x: root.identifierRight + (text ? (root.showId ? 1 : 0) - Math.floor(countMetrics.tightBoundingRect.x) : 0)
    anchors.baseline: number.baseline
    anchors.baselineOffset: -Math.round(numberMetrics.tightBoundingRect.height - countMetrics.tightBoundingRect.height + 2)
    text: root.showCount && root.entry && root.entry.count > 0 ? String(root.entry.count) : ""
    color: root.foreground
    font { family: root.fontFamily; pixelSize: Math.round(root.fontSize * 0.65); bold: true }
  }
  // Under width pressure the title elides first, then the name.
  Text {
    id: name
    objectName: "workspace-label-name"
    x: root.nameStart
    width: Math.max(0, Math.min(root.nameEnd, root.width) - root.nameStart)
    anchors.baseline: number.baseline
    text: root.customName
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.foreground
    font { family: root.fontFamily; pixelSize: root.fontSize; bold: false }
  }
  Text {
    id: titleText
    objectName: "workspace-label-title"
    x: root.titleStart
    width: Math.max(0, root.width - root.titleStart)
    visible: !!root.title && width > 0
    anchors.baseline: number.baseline
    text: root.title
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.foreground
    font { family: root.fontFamily; pixelSize: root.fontSize; bold: false }
  }
}
