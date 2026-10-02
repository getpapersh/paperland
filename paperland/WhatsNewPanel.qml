pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls as QQC

// PaperMac's What's New card: title, newest-first releases, and a single "Got it" dismiss.
FocusScope {
  id: root
  // Each entry is a WhatsNew.js ReleaseNote.
  property var releases: []
  signal dismissed()
  implicitWidth: 480
  implicitHeight: 520
  Keys.onEscapePressed: root.dismissed()
  Keys.onReturnPressed: root.dismissed()
  Keys.onEnterPressed: root.dismissed()
  Keys.onUpPressed: root.scrollBy(-40)
  Keys.onDownPressed: root.scrollBy(40)
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_PageUp) root.scrollBy(-(list.height - 40));
    else if (event.key === Qt.Key_PageDown) root.scrollBy(list.height - 40);
    else if (event.key === Qt.Key_Home) root.scrollBy(-list.contentHeight);
    else if (event.key === Qt.Key_End) root.scrollBy(list.contentHeight);
    else return;
    event.accepted = true;
  }
  readonly property real footerHeight: footer.height
  readonly property real scrollPosition: list.contentY
  readonly property real scrollLimit: Math.max(0, list.contentHeight - list.height)

  function scrollBy(delta: real): void { list.contentY = Math.max(0, Math.min(root.scrollLimit, list.contentY + delta)); }

  function sectionStyle(kind: string): var {
    switch (kind.toLowerCase()) {
    case "added": return { glyph: "+", tint: Theme.success };
    case "fixed": return { glyph: "✓", tint: Theme.warning };
    case "changed": return { glyph: "↻", tint: Theme.accent };
    case "removed": return { glyph: "−", tint: Theme.danger };
    case "deprecated": return { glyph: "!", tint: Theme.warning };
    case "security": return { glyph: "◆", tint: Theme.success };
    default: return { glyph: "•", tint: Theme.textTertiary };
    }
  }
  function heading(kind: string): string { return kind.charAt(0).toUpperCase() + kind.slice(1).toLowerCase(); }

  Rectangle {
    anchors.fill: parent
    radius: 12
    color: Theme.background
    border.color: Theme.borderStrong
  }
  Text {
    id: title
    objectName: "whats-new-title"
    x: 20; y: 20
    width: parent.width - 40
    text: "What's New in Paperland"
    textFormat: Text.PlainText
    color: Theme.textPrimary
    font.family: Theme.fontFamily
    font.pixelSize: 19
    font.bold: true
    Accessible.role: Accessible.Heading
    Accessible.name: text
  }
  Rectangle { id: topRule; y: title.y + title.height + 20; width: parent.width; height: 1; color: Theme.border }
  Flickable {
    id: list
    anchors { top: topRule.bottom; bottom: bottomRule.top; left: parent.left; right: parent.right }
    clip: true
    contentHeight: notes.implicitHeight + 40
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar { }
    Column {
      id: notes
      x: 20; y: 20
      width: list.width - 40
      spacing: 22
      Repeater {
        model: root.releases
        delegate: Column {
          id: release
          required property var modelData
          objectName: "whats-new-release-" + modelData.version
          width: notes.width
          spacing: 10
          Row {
            spacing: 8
            Text {
              id: versionText
              objectName: "whats-new-version"
              text: release.modelData.version
              textFormat: Text.PlainText
              color: Theme.textPrimary
              font.family: Theme.fontFamily
              font.pixelSize: 15
              font.bold: true
            }
            Text {
              y: versionText.baselineOffset - baselineOffset
              visible: text !== ""
              text: release.modelData.date
              textFormat: Text.PlainText
              color: Theme.textTertiary
              font.family: Theme.fontFamily
              font.pixelSize: 11
            }
          }
          Text {
            objectName: "whats-new-headline"
            width: parent.width
            visible: text !== ""
            text: release.modelData.headline
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            color: Theme.textSecondary
            font.family: Theme.fontFamily
            font.pixelSize: 13
          }
          Repeater {
            model: release.modelData.sections
            delegate: Column {
              id: section
              required property var modelData
              readonly property var style: root.sectionStyle(modelData.kind)
              width: release.width
              spacing: 5
              Text {
                objectName: "whats-new-section"
                text: section.style.glyph + " " + root.heading(section.modelData.kind)
                textFormat: Text.PlainText
                color: section.style.tint
                font.family: Theme.fontFamily
                font.pixelSize: 11
                font.bold: true
                font.letterSpacing: 0.4
                Accessible.role: Accessible.Heading
                Accessible.name: root.heading(section.modelData.kind)
              }
              Repeater {
                model: section.modelData.items
                delegate: Row {
                  id: bullet
                  required property string modelData
                  width: section.width
                  spacing: 7
                  Text { id: dot; text: "•"; color: Theme.textTertiary; font.pixelSize: 13 }
                  Text {
                    objectName: "whats-new-item"
                    width: bullet.width - dot.width - bullet.spacing
                    // Bundled, trusted notes: inline Markdown for `code`, **bold** and links.
                    text: bullet.modelData
                    textFormat: Text.MarkdownText
                    wrapMode: Text.Wrap
                    color: Theme.textSecondary
                    linkColor: Theme.accent
                    font.family: Theme.fontFamily
                    font.pixelSize: 13
                    onLinkActivated: function(link) { Qt.openUrlExternally(link); }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  Rectangle { id: bottomRule; anchors.bottom: footer.top; width: parent.width; height: 1; color: Theme.border }
  Item {
    id: footer
    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
    height: gotIt.implicitHeight + 40
    Button {
      id: gotIt
      objectName: "whats-new-got-it"
      anchors { right: parent.right; rightMargin: 20; verticalCenter: parent.verticalCenter }
      text: "Got it"
      selected: true
      fontSize: 14
      onClicked: root.dismissed()
    }
  }
}
