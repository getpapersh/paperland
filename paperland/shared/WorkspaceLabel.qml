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
  readonly property string customName: {
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
  readonly property real identifierRight: count.text
    ? Math.ceil(identifierMetrics.tightBoundingRect.x + identifierMetrics.tightBoundingRect.width)
    : number.implicitWidth
  width: implicitWidth
  implicitWidth: Math.min(maximumWidth, count.x + count.implicitWidth
    + (customName ? nameGap + nameMetrics.advanceWidth : 0))
  implicitHeight: capHeight
  TextMetrics { id: numberMetrics; font: number.font; text: "0" }
  TextMetrics { id: identifierMetrics; font: number.font; text: number.text }
  TextMetrics { id: countMetrics; font: count.font; text: count.text }
  TextMetrics { id: nameMetrics; font: name.font; text: root.customName }
  Text {
    id: number
    objectName: "workspace-label-symbol-text"
    x: 0
    y: root.height - baselineOffset
    text: root.entry ? root.special ? Scratchpad.identifier(root.shortcutBinding) : String(root.entry.id) : ""
    color: root.foreground
    font { family: root.fontFamily; pixelSize: root.fontSize; bold: true }
  }
  Text {
    id: count
    objectName: "workspace-label-count"
    x: root.identifierRight + (text ? 1 - Math.floor(countMetrics.tightBoundingRect.x) : 0)
    anchors.baseline: number.baseline
    anchors.baselineOffset: -Math.round(numberMetrics.tightBoundingRect.height - countMetrics.tightBoundingRect.height + 2)
    text: root.showCount && root.entry && root.entry.count > 0 ? String(root.entry.count) : ""
    color: root.foreground
    font { family: root.fontFamily; pixelSize: Math.round(root.fontSize * 0.65); bold: true }
  }
  Text {
    id: name
    objectName: "workspace-label-name"
    anchors.left: count.right
    anchors.leftMargin: root.customName ? root.nameGap : 0
    anchors.baseline: number.baseline
    anchors.right: parent.right
    text: root.customName
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.foreground
    font { family: root.fontFamily; pixelSize: root.fontSize; bold: false }
  }
}
