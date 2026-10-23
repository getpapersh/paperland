import QtQuick

Item {
  property string address: ""
  property real aspectRatio: 0
  property bool cover: false
  property bool hasContent: false
  property bool cached: false
  property bool showCachedBadge: true
  property double capturedAt: 0
  // Capture-health facts for the diagnostics report. Plain content (fixtures,
  // non-native previews) is its own source while loaded, renderable and never
  // stopped; the native thumbnail binds these to its actual capture, the
  // compositor's export eligibility, and recorded stops.
  property bool captureActive: true
  property bool renderable: true
  property bool stopped: false
}
