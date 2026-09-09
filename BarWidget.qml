import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar pill: rotates through the watchlist showing "SYM PRICE ▲PCT%",
// tinted green/red by the day's move. Left click opens the popup, middle
// click forces a refresh, right click fires a one-line watchlist toast.
BarWidget {
  id: root
  moduleName: "impaler.stocks"

  property var service: null
  property int rotationIndex: 0

  // Gains/losses need real colour, which the (often monochrome) Omarchy
  // themes don't provide — so these two are fixed and tuned to read on
  // both light and dark bars.
  readonly property color upColor: "#3fb950"
  readonly property color downColor: "#f0553f"

  readonly property var tickers: (service && service.tickers) ? service.tickers : []
  readonly property var quotes: (service && service.quotes) ? service.quotes : ({})
  readonly property int rotateSeconds: (service && service.settings) ? service.settings.rotateSeconds : 5

  readonly property var currentTicker: tickers.length > 0 ? tickers[rotationIndex % tickers.length] : null
  readonly property var currentQuote: currentTicker ? quotes[currentTicker.symbol] : null
  readonly property string pillText: currentTicker
    ? Model.rotationLabel(currentTicker, currentQuote)
    : " Stocks"
  readonly property int pillDirection: currentQuote ? Model.direction(currentQuote.changePct) : 0

  function resolveService() {
    if (!bar || !bar.shell) return
    var found = null
    if (typeof bar.shell.serviceFor === "function") found = bar.shell.serviceFor(moduleName)
    if (!found && typeof bar.shell.ensureService === "function") found = bar.shell.ensureService(moduleName)
    if (found !== root.service) root.service = found
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  function refresh() { if (service && service.refresh) service.refresh() }

  function sendSummary() {
    if (summaryProc.running) return
    summaryProc.command = ["omarchy-notification-send", "--app-name", "Stocks", "-g", "",
      "Watchlist", Model.watchlistSummary(root.tickers, root.quotes)]
    summaryProc.running = true
  }

  // ---- popout contract (mirrors weather/BarWidget.qml) ----
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: resolveService()
  onBarChanged: { resolveService(); injectPanel() }

  // bar.shell can arrive after the widget is built; keep trying until the
  // singleton resolves, then push it into the panel.
  Timer {
    interval: 500
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: {
      root.resolveService()
      if (root.service) { running = false; root.injectPanel() }
    }
  }
  onServiceChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Timer {
    interval: Math.max(2, root.rotateSeconds) * 1000
    running: root.tickers.length > 1
    repeat: true
    onTriggered: root.rotationIndex = (root.rotationIndex + 1) % Math.max(1, root.tickers.length)
  }

  Process { id: summaryProc }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    foreground: root.pillDirection > 0
      ? root.upColor
      : (root.pillDirection < 0
        ? root.downColor
        : (root.bar ? root.bar.barForeground : Color.foreground))
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function (b) {
      if (b === Qt.RightButton) root.sendSummary()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
