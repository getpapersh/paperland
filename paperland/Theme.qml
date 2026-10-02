pragma Singleton
import QtQuick

QtObject {
  property color foreground: "#a9b1d6"
  property color background: "#1a1b26"
  property color accent: "#7aa2f7"
  property string fontFamily: "sans-serif"
  // Overview text and surface tokens. Muted text stays at or above 4.5:1 on
  // the board, strip and raised fills; never render text below textTertiary.
  readonly property color textPrimary: foreground
  readonly property color textSecondary: alpha(foreground, 0.80)
  readonly property color textTertiary: alpha(foreground, 0.72)
  readonly property color textDisabled: alpha(foreground, 0.40)
  readonly property color surfaceStrip: alpha(foreground, 0.04)
  readonly property color surfaceCanvas: alpha(foreground, 0.07)
  readonly property color surfaceControl: alpha(foreground, 0.06)
  readonly property color surfaceHover: alpha(foreground, 0.10)
  readonly property color surfaceSelected: alpha(foreground, 0.14)
  readonly property color surfaceRaised: Qt.tint(background, alpha(foreground, 0.06))
  readonly property color border: alpha(foreground, 0.12)
  readonly property color borderStrong: alpha(foreground, 0.22)
  readonly property color borderCanvas: alpha(foreground, 0.18)
  readonly property color borderCanvasCurrent: alpha(accent, 0.55)
  readonly property color accentSoft: alpha(accent, 0.16)
  readonly property color viewportBand: alpha(accent, 0.08)
  readonly property color viewportBorder: alpha(accent, 0.45)
  readonly property color thumbnailLetterbox: alpha("#000000", 0.25)
  readonly property real unmatchedThumbnailOpacity: 0.23
  readonly property color scrim: Qt.rgba(0, 0, 0, 0.75)
  // Workspace switch card: translucent over arbitrary desktop content, so its
  // text tiers are held to 4.5:1 over both black and white backdrops
  // (tests/ThemeContrast.test.js).
  readonly property color switchCardSurface: alpha(background, 0.92)
  // Status tints for text on Theme.background, such as What's New section headings.
  readonly property color success: "#9ece6a"
  readonly property color warning: "#e0af68"
  readonly property color danger: "#f7768e"
  // Alt+Tab switcher. A warm dark surface family, independent of the overview
  // tokens above; text tiers are held to WCAG 4.5:1 on the fills they draw on
  // (tests/ThemeContrast.test.js).
  readonly property color switcherScrim: "#70000000"
  readonly property color switcherSurface: "#272727"
  readonly property color switcherSurfaceBorder: "#555055"
  readonly property color switcherCard: "#302c30"
  readonly property color switcherCardHover: "#393339"
  readonly property color switcherCardSelected: "#513651"
  readonly property color switcherCardBorder: "#514751"
  readonly property color switcherCardBorderSelected: "#d990d9"
  readonly property color switcherFooter: "#211d21"
  readonly property color switcherKeycap: "#1c191c"
  readonly property color switcherTextPrimary: "#eeeeee"
  readonly property color switcherTextSecondary: "#dfd5df"
  readonly property color switcherTextTertiary: "#c4bac4"
  readonly property color switcherTextKeycap: "#d5ccd5"
  readonly property color switcherTextHint: "#9c929c"
  // Search status pill "No matches".
  readonly property color switcherTextDanger: "#ff8a8a"
  // Naming-control hover, and the SWITCHER SIZE popover with its row states.
  readonly property color switcherControlHover: "#4a3f4a"
  readonly property color switcherPopover: "#161316"
  readonly property color switcherPopoverRowHover: "#2c272c"
  readonly property color switcherPopoverRowSelected: "#3a333a"
  function alpha(color, opacity) { return Qt.rgba(color.r, color.g, color.b, opacity); }
  // The standalone app reads the optional palette; importing Omarchy's shell would make it a dependency.
  // The file reader itself lives in shell.qml (Quickshell owns FileView), so this
  // singleton stays pure QtQuick and loadable by the plain-Qt component checks.
  property var systemPalette: ({})
  readonly property color settingsSystemBackground: systemPalette.background || "#191d2c"
  readonly property color settingsSystemForeground: systemPalette.foreground || "#d6dcf5"
  readonly property color settingsSystemAccent: systemPalette.accent || "#5b82f6"
  signal paletteRefreshRequested()
  function refreshSettingsColors(): void { paletteRefreshRequested(); }
  function readSettingsPalette(text: string): void {
    var colors = {}, lines = text.split("\n");
    for (var i = 0; i < lines.length; i++) {
      var match = /^\s*([a-z_]+)\s*=\s*["'](#[0-9a-fA-F]{6})["']\s*(?:#.*)?$/.exec(lines[i]);
      if (match) colors[match[1]] = match[2];
    }
    systemPalette = colors.background && colors.foreground && colors.accent ? colors : ({});
  }
  function settingsColor(fallback: string): color {
    var palette = systemPalette;
    if (!palette.background) return fallback;
    var bg = settingsSystemBackground, fg = settingsSystemForeground, selected = settingsSystemAccent;
    if (["#191d2c", "#151a27"].indexOf(fallback) !== -1) return bg;
    if (["#171b29", "#111b31", "#111e34"].indexOf(fallback) !== -1) return palette.dark_background || bg;
    if (["#202638", "#202639", "#1b2234", "#1c2638", "#172440"].indexOf(fallback) !== -1) return palette.lighter_background || Qt.tint(bg, alpha(fg, 0.07));
    if (["#262c40", "#242b3e", "#30384d", "#303950", "#303a56", "#2c344b", "#2d4165"].indexOf(fallback) !== -1) return Qt.tint(bg, alpha(fg, 0.10));
    if (fallback === "#303765") return palette.selection || Qt.tint(bg, alpha(selected, 0.18));
    // Review note: accent-tinted callout surface and border.
    if (fallback === "#243552") return Qt.tint(bg, alpha(selected, 0.16));
    if (fallback === "#466db0") return alpha(selected, 0.45);
    if (["#5b82f6", "#6488ff", "#81a0ff", "#7fa0ff", "#7b9aff", "#7194ff", "#93b1ff", "#b0c1ff", "#6588bc"].indexOf(fallback) !== -1) return selected;
    if (fallback === "#4664ba") return Qt.darker(selected, 1.1);
    if (fallback === "#10192f") return accentInk(selected);
    if (["#8fcaac", "#91d5b0", "#93ccb2"].indexOf(fallback) !== -1) return palette.green || fg;
    if (["#e5c18a", "#eac487", "#eec588", "#efc989"].indexOf(fallback) !== -1) return palette.yellow || fg;
    if (fallback === "#ec9ba8") return palette.red || fg;
    if (["#37415b", "#38415d", "#39445e", "#3a425b", "#3c4665", "#414c69", "#414c6b", "#414b65", "#45526e", "#46506b", "#586787"].indexOf(fallback) !== -1) return Qt.tint(bg, alpha(fg, 0.22));
    if (["#9299bc", "#929cbe", "#9ea7ca", "#a6b2d1", "#a8afd1", "#adb4d7", "#b0b8d8", "#b3c5e9", "#7596bc"].indexOf(fallback) !== -1) return Qt.tint(bg, alpha(fg, 0.78));
    if (["#78819f", "#78839f", "#929bb4", "#777e9d", "#577391"].indexOf(fallback) !== -1) return Qt.tint(bg, alpha(fg, 0.55));
    if (["#080b15", "#0a0c17"].indexOf(fallback) !== -1) return fallback;
    // Bright text on mapped surfaces. Anything unlisted keeps its literal color:
    // an unknown role must stay visible, never silently become the text color.
    if (["#d6dcf5", "#d5ddf5", "#d4d1ff", "#d9d4ff", "#d2d9f4", "#ddd9ff", "#e2e0ff", "#dce5ff",
         "#d3d9ef", "#d1d8ef", "#c9d1ea", "#c5d2f4", "#c4cbe7", "#c3c9e5", "#c1ccec",
         "#bbc8e6", "#b8c9f4", "#b4bad7"].indexOf(fallback) !== -1) return fg;
    return fallback;
  }
  function accentInk(color: color): color {
    var channels = [color.r, color.g, color.b].map(function(value) {
      return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
    });
    var luminance = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
    return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? "#101010" : "#ffffff";
  }

}
