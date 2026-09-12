import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The watchlist popup: hero quote + intraday sparkline, the full watchlist,
// a per-ticker alert editor, and an add-ticker field. Structure mirrors
// weather/Panel.qml and clock/Panel.qml (KeyboardPanel + PanelKeyCatcher +
// Flickable), and BarWidget.qml owns the bar label and anchors this panel.
Panel {
  id: root
  moduleName: "impaler.stocks"
  ipcTarget: "impaler.stocks"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property bool openedFromHotkey: false
  readonly property var barIdentity: hostWidget || root

  property string selectedSymbol: ""
  property bool adding: false
  property bool validating: false
  property string addError: ""
  property string addPending: ""
  property bool settingsOpen: false
  property var searchResults: []
  property string searchIssued: ""
  property int searchIndex: -1
  property var lastRemovedTicker: null
  property int lastRemovedIndex: -1

  // Hero-chart time frame. "1d" reuses the live spark from the quote feed;
  // every longer range is a one-shot fetch against v8/finance/chart, cached
  // by "SYMBOL|range" so flipping back and forth doesn't refetch.
  readonly property string chartRange: root.state.settings.chartRange || "1d"
  property var chartSeries: []
  property bool chartLoading: false
  property string chartLoadedKey: ""
  property bool chartFailed: false

  readonly property string chartRequest:
    (root.selectedTicker ? root.selectedTicker.symbol : "") + "|" + root.chartRange
  onChartRequestChanged: {
    if (root.chartRange !== "1d" && root.chartRequest !== root.chartLoadedKey)
      root.chartSeries = []
    root.chartFailed = false
    Qt.callLater(root.loadChart)
  }

  // The host BarWidget injects `service`, but fall back to resolving it
  // ourselves from bar.shell in case that injection is missed or late.
  function resolveOwnService() {
    if (root.service || !root.bar || !root.bar.shell) return
    var s = null
    if (typeof root.bar.shell.serviceFor === "function") s = root.bar.shell.serviceFor(root.moduleName)
    if (!s && typeof root.bar.shell.ensureService === "function") s = root.bar.shell.ensureService(root.moduleName)
    if (s) root.service = s
  }
  onBarChanged: resolveOwnService()
  Timer {
    interval: 500
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: { root.resolveOwnService(); if (root.service) running = false }
  }

  readonly property var state: (service && service.state) ? service.state : Model.defaultState()
  readonly property var tickers: root.state.tickers
  readonly property var quotes: (service && service.quotes) ? service.quotes : ({})

  readonly property var selectedTicker: {
    var list = root.tickers
    if (!list || list.length === 0) return null
    for (var i = 0; i < list.length; i++)
      if (list[i].symbol === root.selectedSymbol) return list[i]
    return list[0]
  }
  readonly property var selectedQuote: root.selectedTicker ? root.quotes[root.selectedTicker.symbol] : null
  readonly property int selectedIndex: {
    for (var i = 0; i < root.tickers.length; i++)
      if (root.tickers[i].symbol === root.selectedSymbol) return i
    return root.tickers.length > 0 ? 0 : -1
  }

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color upColor: "#3fb950"
  readonly property color downColor: "#f0553f"

  function dirColor(v) {
    var d = Model.direction(v)
    if (d > 0) return root.upColor
    if (d < 0) return root.downColor
    return Qt.darker(root.contentForeground, 1.4)
  }

  // ---------------------------------------------------------- lifecycle ----

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    if (service && service.reloadState) service.reloadState()
    if (service && service.refresh) service.refresh()
    Qt.callLater(root.loadChart)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    if (service && service.reloadState) service.reloadState()
    if (service && service.refresh) service.refresh()
    Qt.callLater(root.loadChart)
    Qt.callLater(function () {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.adding) cancelAdd()
    root.controller.hide()
  }

  function toggle() { root.opened ? root.close() : root.openFromHotkey() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ------------------------------------------------- watchlist mutations ----

  function selectSymbol(sym) { root.selectedSymbol = String(sym || "") }

  function stepSelection(delta) {
    var list = root.tickers
    if (!list || list.length === 0) return
    var idx = 0
    for (var i = 0; i < list.length; i++)
      if (list[i].symbol === root.selectedSymbol) { idx = i; break }
    idx = (idx + delta + list.length) % list.length
    root.selectedSymbol = list[idx].symbol
  }

  function tickerInDraft(draft, sym) {
    var s = String(sym).toUpperCase()
    var list = (draft.tickers || [])
    for (var i = 0; i < list.length; i++)
      if (String(list[i].symbol).toUpperCase() === s) return list[i]
    return null
  }

  function removeSymbol(sym) {
    var s = String(sym).toUpperCase()
    var list = root.state.tickers || []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].symbol).toUpperCase() === s) {
        root.lastRemovedTicker = JSON.parse(JSON.stringify(list[i]))
        root.lastRemovedIndex = i
        undoTimer.restart()
        break
      }
    }
    root.mutateState(function (draft) {
      draft.tickers = (draft.tickers || []).filter(function (t) {
        return String(t.symbol).toUpperCase() !== s
      })
    })
  }

  function moveSelected(delta) {
    var from = root.selectedIndex
    var to = from + delta
    if (from < 0 || to < 0 || to >= root.tickers.length) return
    root.mutateState(function (draft) {
      var moved = draft.tickers.splice(from, 1)[0]
      draft.tickers.splice(to, 0, moved)
    })
  }

  function undoRemove() {
    if (!root.lastRemovedTicker) return
    var restored = root.lastRemovedTicker
    var at = root.lastRemovedIndex
    root.mutateState(function (draft) {
      var list = draft.tickers || []
      list.splice(Math.max(0, Math.min(at, list.length)), 0, restored)
      draft.tickers = list
    })
    root.selectedSymbol = restored.symbol
    root.lastRemovedTicker = null
    undoTimer.stop()
  }

  Timer {
    id: undoTimer
    interval: 6000
    onTriggered: root.lastRemovedTicker = null
  }

  function startAdd() {
    root.adding = true
    root.addError = ""
    Qt.callLater(function () {
      addField.text = ""
      addField.forceActiveFocus()
    })
  }

  function cancelAdd() {
    root.adding = false
    root.validating = false
    root.addError = ""
    root.addPending = ""
    root.searchResults = []
    root.searchIndex = -1
    searchTimer.stop()
    Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitAdd() {
    if (root.searchIndex >= 0 && root.searchIndex < root.searchResults.length) {
      addSearchResult(root.searchResults[root.searchIndex])
      return
    }
    var raw = String(addField.text || "").trim().toUpperCase()
    if (raw === "") { cancelAdd(); return }
    if (Model.findTicker(root.state, raw)) {
      root.selectedSymbol = raw
      cancelAdd()
      return
    }
    root.addPending = raw
    root.addError = ""
    root.validating = true
    validateProc.command = Model.curlCommand(
      "https://query1.finance.yahoo.com/v8/finance/chart/"
        + encodeURIComponent(raw) + "?range=1d&interval=1d",
      8, Model.MAX_CHART_BYTES)
    validateProc.running = true
  }

  function addSearchResult(result) {
    if (!result || !result.symbol) return
    var sym = String(result.symbol).toUpperCase()
    if (Model.findTicker(root.state, sym)) {
      root.selectedSymbol = sym
      cancelAdd()
      return
    }
    root.mutateState(function (draft) {
      draft.tickers = (draft.tickers || []).concat([{
        symbol: sym,
        name: result.name || "",
        currency: "",
        exchange: result.exchange || "",
        alerts: []
      }])
    })
    root.selectedSymbol = sym
    root.adding = false
    root.searchResults = []
    root.searchIndex = -1
    if (root.service && root.service.refresh) root.service.refresh()
    Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function queueSearch() {
    root.searchIndex = -1
    root.addError = ""
    var query = String(addField.text || "").trim()
    if (query.length < 2) {
      searchTimer.stop()
      root.searchResults = []
      return
    }
    searchTimer.restart()
  }

  function startSearch() {
    var query = String(addField.text || "").trim()
    if (query.length < 2) return
    if (searchProc.running) return
    root.searchIssued = query
    searchProc.command = Model.curlCommand(
      "https://query2.finance.yahoo.com/v1/finance/search?q="
        + encodeURIComponent(query) + "&quotesCount=8&newsCount=0",
      8, Model.MAX_SEARCH_BYTES)
    searchProc.running = true
  }

  Timer {
    id: searchTimer
    interval: 280
    onTriggered: root.startSearch()
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var current = String(addField.text || "").trim()
        if (current === root.searchIssued)
          root.searchResults = Model.parseSearch(String(text || ""), 8)
        else if (current.length >= 2)
          searchTimer.restart()
      }
    }
  }

  Process {
    id: validateProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        root.validating = false
        if (raw === "") {
          root.addError = "Couldn’t reach the quote service — try again"
          return
        }
        var meta = Model.parseChartMeta(raw)
        if (!meta.ok) {
          root.addError = "Unknown symbol “" + root.addPending + "”"
          return
        }
        var sym = root.addPending
        root.mutateState(function (draft) {
          draft.tickers = (draft.tickers || []).concat([{
            symbol: sym,
            name: meta.name,
            currency: meta.currency,
            exchange: meta.exchange,
            alerts: []
          }])
        })
        root.selectedSymbol = sym
        root.addPending = ""
        root.adding = false
        if (root.service && root.service.refresh) root.service.refresh()
        Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
      }
    }
  }

  // -------------------------------------------------------- hero chart ----

  // Series the hero sparkline plots: the live intraday spark for "1d", the
  // fetched close series for any longer range.
  readonly property var heroSeries: root.chartRange === "1d"
    ? (root.selectedQuote ? root.selectedQuote.spark : [])
    : root.chartSeries

  // Move shown beside the hero price. "1d" stays anchored to the previous
  // close (matching the watchlist rows and bar pill); longer ranges report
  // the move across the visible window.
  readonly property var heroMove: {
    if (root.chartRange === "1d") {
      var q = root.selectedQuote
      return {
        change: q ? q.change : null,
        changePct: q ? q.changePct : null,
        caption: "since previous close"
      }
    }
    var pc = Model.periodChange(root.heroSeries)
    return {
      change: pc.change,
      changePct: pc.changePct,
      caption: "past " + Model.chartRangeLabel(root.chartRange)
    }
  }

  function setChartRange(value) {
    if (Model.chartRangeValues().indexOf(String(value)) === -1) return
    root.updateSetting("chartRange", String(value))
  }

  function stepChartRange(delta) {
    var vals = Model.chartRangeValues()
    var i = vals.indexOf(root.chartRange)
    if (i === -1) i = 0
    root.setChartRange(vals[Math.max(0, Math.min(vals.length - 1, i + delta))])
  }

  function loadChart() {
    if (root.chartRange === "1d") { root.chartLoading = false; return }
    var ticker = root.selectedTicker
    if (!ticker) return
    var key = root.chartRequest
    if (key === root.chartLoadedKey && root.chartSeries.length > 1) return
    if (chartProc.running) return
    var spec = Model.chartRangeSpec(root.chartRange)
    root.chartLoading = true
    root.chartFailed = false
    root._chartPending = key
    chartProc.command = Model.curlCommand(
      "https://query1.finance.yahoo.com/v8/finance/chart/"
        + encodeURIComponent(ticker.symbol)
        + "?" + Model.chartQuery(spec.value, Date.now() / 1000),
      10, Model.MAX_CHART_BYTES)
    chartProc.running = true
  }

  property string _chartPending: ""

  Process {
    id: chartProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.chartLoading = false
        var parsed = Model.parseChart(String(text || ""))
        // Ignore a response whose request the selection has already moved past.
        if (root._chartPending !== root.chartRequest) { Qt.callLater(root.loadChart); return }
        if (!parsed.ok || parsed.closes.length < 2) {
          root.chartFailed = true
          root.chartSeries = []
          return
        }
        root.chartSeries = parsed.closes
        root.chartLoadedKey = root._chartPending
        root.chartFailed = false
      }
    }
  }

  // ----------------------------------------------------- alert mutations ----

  function addAlert(sym) {
    var s = String(sym).toUpperCase()
    var q = root.quotes[s]
    var seed = Model.defaultAlertValue("above", q)
    root.mutateState(function (draft) {
      var t = root.tickerInDraft(draft, s)
      if (!t) return
      if (!Array.isArray(t.alerts)) t.alerts = []
      t.alerts.push({ id: Model.genId(), type: "above", value: seed, enabled: true })
    })
  }

  function updateAlert(sym, alertId, patch) {
    var s = String(sym).toUpperCase()
    root.mutateState(function (draft) {
      var t = root.tickerInDraft(draft, s)
      if (!t || !Array.isArray(t.alerts)) return
      for (var i = 0; i < t.alerts.length; i++) {
        if (t.alerts[i].id !== alertId) continue
        for (var k in patch) t.alerts[i][k] = patch[k]
      }
    })
  }

  function removeAlert(sym, alertId) {
    var s = String(sym).toUpperCase()
    root.mutateState(function (draft) {
      var t = root.tickerInDraft(draft, s)
      if (!t || !Array.isArray(t.alerts)) return
      t.alerts = t.alerts.filter(function (a) { return a.id !== alertId })
    })
  }

  function updateSetting(key, value) {
    root.mutateState(function (draft) {
      if (!draft.settings) draft.settings = Model.defaultSettings()
      draft.settings[key] = value
    })
  }

  // Keep the selection valid as the list changes underneath us.
  function mutateState(fn) {
    if (root.service && root.service.mutateState) root.service.mutateState(fn)
  }

  Connections {
    target: root.service
    function onStateChanged() {
      var list = root.tickers
      if (!list || list.length === 0) { root.selectedSymbol = ""; return }
      for (var i = 0; i < list.length; i++)
        if (list[i].symbol === root.selectedSymbol) return
      root.selectedSymbol = list[0].symbol
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function add(): void { root.openFromHotkey(); root.startAdd() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.adding
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) {
        if (dy !== 0) root.stepSelection(dy)
        else if (dx !== 0) root.stepSelection(dx)
      }
      onTextKey: function (t) {
        if (t === "[") root.stepSelection(-1)
        else if (t === "]") root.stepSelection(1)
        else if (t === "," || t === "<") root.stepChartRange(-1)
        else if (t === "." || t === ">") root.stepChartRange(1)
        else if (t === "a" || t === "+") root.startAdd()
        else if (t === "s") root.settingsOpen = !root.settingsOpen
        else if (t === "r") { if (root.service && root.service.refresh) root.service.refresh() }
      }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

          Column {
            id: contentColumn
            width: scroll.width
            spacing: Style.space(14)

            Row {
              visible: root.tickers.length > 0
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: parent.width - refreshStatus.width - parent.spacing
                text: root.service && root.service.fetchError ? root.service.fetchError : ""
                elide: Text.ElideRight
                color: root.bar ? root.bar.urgent : Color.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: refreshStatus
                text: root.service && root.service.fetching
                  ? "Refreshing…"
                  : Model.formatUpdateTime(root.service ? root.service.lastUpdatedMs : 0)
                color: Qt.darker(root.contentForeground, 1.6)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

          // ---- empty state -------------------------------------------------
          Text {
            visible: root.tickers.length === 0 && !root.adding
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Build your watchlist\n\nSearch a company name or Yahoo Finance symbol below — such as “Apple”, AAPL, ^GSPC, GBPUSD=X, or BTC-USD — and pick a result. Quotes refresh in the background and alerts keep working while Omarchy Shell is running."
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- hero ------------------------------------------------------
          Column {
            visible: root.selectedTicker !== null
            width: parent.width
            spacing: Style.space(3)

            Text {
              text: root.selectedTicker ? root.selectedTicker.symbol : ""
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: root.selectedTicker ? (root.selectedTicker.name || "") : ""
              color: Qt.darker(root.contentForeground, 1.5)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }

            Row {
              spacing: Style.space(12)
              topPadding: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedQuote ? Model.formatPrice(root.selectedQuote.price) : "·····"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  text: root.heroMove.changePct !== null
                    ? Model.arrow(root.heroMove.changePct) + " " + Model.formatSignedChange(root.heroMove.change)
                    : ""
                  color: root.dirColor(root.heroMove.changePct)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  text: root.heroMove.changePct !== null
                    ? Model.formatSignedPct(root.heroMove.changePct) + "  ·  " + root.heroMove.caption
                    : (root.chartLoading ? "Loading " + Model.chartRangeLabel(root.chartRange) + "…" : "")
                  color: root.dirColor(root.heroMove.changePct)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
            }

            Sparkline {
              width: parent.width
              height: Style.space(64)
              values: root.heroSeries
              filled: true
              lineThickness: 1.8
              lineColor: root.dirColor(root.heroMove.changePct)
              fillColor: lineColor
            }

            // ---- time-frame selector ----
            Flow {
              width: parent.width
              spacing: Style.space(4)
              topPadding: Style.space(2)

              Repeater {
                model: Model.CHART_RANGES

                Button {
                  required property var modelData
                  text: modelData.label
                  bordered: true
                  selected: modelData.value === root.chartRange
                  fontFamily: root.contentFontFamily
                  fontSize: Style.font.caption
                  foreground: root.contentForeground
                  horizontalPadding: Style.space(7)
                  verticalPadding: Style.space(4)
                  onClicked: root.setChartRange(modelData.value)
                }
              }
            }

            Text {
              visible: root.chartFailed
              width: parent.width
              text: "Couldn’t load the " + Model.chartRangeLabel(root.chartRange) + " chart — showing what’s cached"
              color: root.bar ? root.bar.urgent : Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.selectedTicker !== null
              text: {
                var q = root.selectedQuote
                var currency = q && q.currency ? q.currency : (root.selectedTicker ? root.selectedTicker.currency : "")
                var exchange = q && q.exchange ? q.exchange : (root.selectedTicker ? root.selectedTicker.exchange : "")
                var market = q && q.marketState ? q.marketState.replace(/_/g, " ").toLowerCase() : ""
                return [currency, exchange, market].filter(function (v) { return v !== "" }).join(" · ")
              }
              color: Qt.darker(root.contentForeground, 1.6)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSeparator { visible: root.tickers.length > 0 }

          // ---- watchlist ------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.tickers

              Rectangle {
                id: rowRect
                required property var modelData
                required property int index

                readonly property var rowQuote: root.quotes[modelData.symbol]
                readonly property bool selected: modelData.symbol === (root.selectedTicker ? root.selectedTicker.symbol : "")

                width: parent.width
                height: Style.space(48)
                radius: Style.cornerRadius
                color: (selected || rowMouse.containsMouse)
                  ? Style.hoverFillFor(root.contentForeground, Color.accent)
                  : "transparent"

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectSymbol(rowRect.modelData.symbol)
                }

                readonly property color rowDir: root.dirColor(rowRect.rowQuote ? rowRect.rowQuote.changePct : null)

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(10)

                  // symbol + name
                  Column {
                    width: Style.space(150)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      text: rowRect.modelData.symbol
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                    Text {
                      visible: text !== ""
                      width: parent.width
                      text: rowRect.modelData.name || ""
                      color: Qt.darker(root.contentForeground, 1.6)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  // intraday spark, coloured by the 24h move
                  Sparkline {
                    width: Style.space(80)
                    height: Style.space(24)
                    anchors.verticalCenter: parent.verticalCenter
                    values: rowRect.rowQuote ? rowRect.rowQuote.spark : []
                    filled: true
                    lineThickness: 1.4
                    lineColor: rowRect.rowDir
                    fillColor: rowRect.rowDir
                  }

                  // price + a coloured 24h %-change badge
                  Column {
                    width: Style.space(96)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(3)

                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignRight
                      text: rowRect.rowQuote ? Model.formatPrice(rowRect.rowQuote.price) : "·····"
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Rectangle {
                      anchors.right: parent.right
                      visible: rowRect.rowQuote !== undefined && rowRect.rowQuote.changePct !== null
                      implicitWidth: pctText.implicitWidth + Style.space(10)
                      implicitHeight: pctText.implicitHeight + Style.space(3)
                      radius: Style.cornerRadius > 0 ? height / 2 : 0
                      color: Qt.rgba(rowRect.rowDir.r, rowRect.rowDir.g, rowRect.rowDir.b, 0.16)

                      Text {
                        id: pctText
                        anchors.centerIn: parent
                        text: (rowRect.rowQuote ? Model.arrow(rowRect.rowQuote.changePct) : "")
                          + " " + (rowRect.rowQuote ? Model.formatSignedPct(rowRect.rowQuote.changePct) : "")
                        color: rowRect.rowDir
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }

                  PanelActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: (rowMouse.containsMouse || removeHover.hovered) ? 1 : 0.45
                    iconText: "×"
                    tooltipText: "Remove " + rowRect.modelData.symbol
                    foreground: root.contentForeground
                    hoverColor: root.bar ? root.bar.urgent : Color.urgent
                    fontFamily: root.contentFontFamily
                    onClicked: root.removeSymbol(rowRect.modelData.symbol)
                    HoverHandler { id: removeHover }
                  }
                }
              }
            }
          }

          Row {
            visible: root.lastRemovedTicker !== null
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width - undoButton.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: root.lastRemovedTicker ? root.lastRemovedTicker.symbol + " removed" : ""
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Button {
              id: undoButton
              text: "Undo"
              bordered: true
              fontFamily: root.contentFontFamily
              foreground: root.contentForeground
              onClicked: root.undoRemove()
            }
          }

          PanelSeparator { visible: root.selectedTicker !== null }

          // ---- alerts for the selected ticker --------------------------
          Column {
            visible: root.selectedTicker !== null
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "ALERTS · " + (root.selectedTicker ? root.selectedTicker.symbol : "")
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Text {
                width: parent.width - earlierButton.width - laterButton.width - parent.spacing * 2
                anchors.verticalCenter: parent.verticalCenter
                text: "Watchlist position"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Button {
                id: earlierButton
                text: "↑ Earlier"
                bordered: true
                enabled: root.selectedIndex > 0
                fontFamily: root.contentFontFamily
                foreground: root.contentForeground
                onClicked: root.moveSelected(-1)
              }
              Button {
                id: laterButton
                text: "↓ Later"
                bordered: true
                enabled: root.selectedIndex >= 0 && root.selectedIndex < root.tickers.length - 1
                fontFamily: root.contentFontFamily
                foreground: root.contentForeground
                onClicked: root.moveSelected(1)
              }
            }

            Text {
              visible: !root.selectedTicker || (root.selectedTicker.alerts || []).length === 0
              text: "No alerts on this ticker"
              color: Qt.darker(root.contentForeground, 1.6)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Repeater {
              model: root.selectedTicker ? root.selectedTicker.alerts : []

              Row {
                id: alertRow
                required property var modelData

                readonly property string sym: root.selectedTicker ? root.selectedTicker.symbol : ""
                readonly property bool isPct: modelData.type === "pctMove"

                width: parent.width
                spacing: Style.space(8)

                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: alertRow.modelData.enabled
                  foreground: root.contentForeground
                  onToggled: root.updateAlert(alertRow.sym, alertRow.modelData.id,
                    { enabled: !alertRow.modelData.enabled })
                }

                Dropdown {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(128)
                  showLabel: false
                  fontFamily: root.contentFontFamily
                  options: [
                    { value: "above", label: "Rises above" },
                    { value: "below", label: "Falls below" },
                    { value: "pctMove", label: "Moves ±% / day" }
                  ]
                  value: alertRow.modelData.type
                  onChanged: function (v) {
                    root.updateAlert(alertRow.sym, alertRow.modelData.id, {
                      type: v,
                      value: Model.defaultAlertValue(v, root.quotes[alertRow.sym])
                    })
                  }
                }

                TextField {
                  id: valueField
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(88)
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  horizontalAlignment: TextInput.AlignRight
                  inputMethodHints: Qt.ImhFormattedNumbersOnly
                  validator: DoubleValidator { bottom: 0; decimals: 4; notation: DoubleValidator.StandardNotation }
                  text: String(alertRow.modelData.value)
                  onEditingFinished: {
                    var n = parseFloat(text)
                    if (isFinite(n)) root.updateAlert(alertRow.sym, alertRow.modelData.id, { value: n })
                  }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: alertRow.isPct ? "%" : ""
                  color: Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }

                Item { width: 1; height: 1 }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "×"
                  tooltipText: "Delete alert"
                  foreground: root.contentForeground
                  hoverColor: root.bar ? root.bar.urgent : Color.urgent
                  fontFamily: root.contentFontFamily
                  onClicked: root.removeAlert(alertRow.sym, alertRow.modelData.id)
                }
              }
            }

            Button {
              text: "+ Add alert"
              bordered: true
              fontFamily: root.contentFontFamily
              foreground: root.contentForeground
              onClicked: root.addAlert(root.selectedTicker.symbol)
            }
          }

          PanelSeparator {}

          Button {
            text: "⚙ Settings"
            bordered: true
            selected: root.settingsOpen
            fontFamily: root.contentFontFamily
            foreground: root.contentForeground
            onClicked: root.settingsOpen = !root.settingsOpen
          }

          Column {
            visible: root.settingsOpen
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Text { width: parent.width - refreshField.width - parent.spacing; text: "Refresh quotes (seconds)"; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.body }
              TextField {
                id: refreshField
                width: Style.space(80)
                text: String(root.state.settings.refreshSeconds)
                foreground: root.contentForeground
                horizontalAlignment: TextInput.AlignRight
                validator: IntValidator { bottom: 15; top: 3600 }
                onEditingFinished: root.updateSetting("refreshSeconds", parseInt(text, 10))
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Text { width: parent.width - rotateField.width - parent.spacing; text: "Rotate bar ticker (seconds)"; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.body }
              TextField {
                id: rotateField
                width: Style.space(80)
                text: String(root.state.settings.rotateSeconds)
                foreground: root.contentForeground
                horizontalAlignment: TextInput.AlignRight
                validator: IntValidator { bottom: 2; top: 60 }
                onEditingFinished: root.updateSetting("rotateSeconds", parseInt(text, 10))
              }
            }
          }

          PanelSeparator {}

          // ---- add ticker ---------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: addField
              width: parent.width - addBtn.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              enabled: !root.validating
              placeholderText: "Search company or symbol"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              onTextChanged: root.queueSearch()
              Keys.onPressed: function (event) {
                if (event.key === Qt.Key_Escape) { root.cancelAdd(); event.accepted = true }
                else if (event.key === Qt.Key_Down && root.searchResults.length > 0) {
                  root.searchIndex = Math.min(root.searchIndex + 1, root.searchResults.length - 1)
                  event.accepted = true
                }
                else if (event.key === Qt.Key_Up && root.searchResults.length > 0) {
                  root.searchIndex = Math.max(root.searchIndex - 1, 0)
                  event.accepted = true
                }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitAdd(); event.accepted = true
                }
              }
            }

            Button {
              id: addBtn
              anchors.verticalCenter: parent.verticalCenter
              text: root.validating ? "…" : "Add"
              bordered: true
              enabled: !root.validating
              fontFamily: root.contentFontFamily
              foreground: root.contentForeground
              onClicked: root.commitAdd()
            }
          }

          Column {
            visible: root.adding && root.searchResults.length > 0
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.searchResults
              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: Style.space(42)
                radius: Style.cornerRadius
                color: (index === root.searchIndex || resultMouse.containsMouse)
                  ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"

                MouseArea {
                  id: resultMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.addSearchResult(parent.modelData)
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(10)
                  Text {
                    width: Style.space(76)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.symbol
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Column {
                    width: parent.width - Style.space(86)
                    anchors.verticalCenter: parent.verticalCenter
                    Text { width: parent.width; text: modelData.name || modelData.symbol; elide: Text.ElideRight; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.bodySmall }
                    Text { width: parent.width; text: [modelData.exchange, modelData.type].filter(function(v) { return v }).join(" · "); elide: Text.ElideRight; color: Qt.darker(root.contentForeground, 1.6); font.family: root.contentFontFamily; font.pixelSize: Style.font.caption }
                  }
                }
              }
            }
          }

          Text {
            visible: root.addError !== ""
            text: root.addError
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.tickers.length > 0
            width: parent.width
            text: "[ ] switch ticker · , . chart range · a add · s settings · r refresh"
            color: Qt.darker(root.contentForeground, 1.9)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: "Quotes supplied by Yahoo Finance · internet access and curl required"
            color: Qt.darker(root.contentForeground, 1.9)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
