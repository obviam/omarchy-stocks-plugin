import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless singleton. Loaded by the shell whenever the plugin is enabled
// (i.e. the pill is on the bar, or the id is listed in shell.json's
// plugins[]), independent of whether the popup is open — so alert checks
// keep running with the panel closed.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // Latest quotes keyed by uppercase symbol. Retained on fetch failure so
  // stale data stays visible rather than blanking.
  property var quotes: ({})
  property bool fetching: false
  property int retries: 0
  property string lastSymbols: ""

  signal quotesUpdated()

  readonly property var settings: store.state.settings
  readonly property var tickers: store.state.tickers
  readonly property string symbolsParam: Model.symbolList(store.state).join(",")

  StocksStore { id: store }

  function refresh() {
    if (root.symbolsParam === "") {
      root.quotes = ({})
      return
    }
    if (fetchProc.running) return
    root.retries = 0
    startFetch()
  }

  function startFetch() {
    root.fetching = true
    fetchProc.command = ["curl", "-fsS", "-A", "Mozilla/5.0", "--max-time", "10",
      "https://query1.finance.yahoo.com/v8/finance/spark?symbols="
        + encodeURIComponent(root.symbolsParam) + "&range=1d&interval=5m"]
    fetchProc.running = true
  }

  function scheduleRetry() {
    root.fetching = false
    if (root.retries >= 3) return
    root.retries++
    retryTimer.restart()
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) { root.scheduleRetry(); return }
        var parsed = Model.parseSpark(raw)
        if (!parsed || Object.keys(parsed).length === 0) { root.scheduleRetry(); return }

        var merged = ({})
        for (var k in root.quotes) merged[k] = root.quotes[k]
        for (var s in parsed) merged[s] = parsed[s]
        root.quotes = merged
        root.retries = 0
        root.fetching = false
        root.quotesUpdated()
        root.evaluateAlerts()
      }
    }
  }

  Timer {
    id: retryTimer
    interval: 3000
    onTriggered: if (!fetchProc.running) root.startFetch()
  }

  Timer {
    id: refreshTimer
    interval: Math.max(15, root.settings.refreshSeconds) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // React to watchlist edits: a changed symbol set triggers a refetch;
  // otherwise (an alert was added/edited/toggled) just re-run the alert
  // check against the quotes we already have, so a new alert can fire
  // without waiting for the next refresh tick. The service's own
  // alertState writes come back through here too and are the no-op case.
  Connections {
    target: store
    function onChanged() {
      if (root.symbolsParam !== root.lastSymbols) {
        root.lastSymbols = root.symbolsParam
        Qt.callLater(root.refresh)
      } else if (!root.evaluating) {
        Qt.callLater(root.evaluateAlerts)
      }
    }
  }

  // ------------------------------------------------------------- alerts ----

  property var noteQueue: []
  property bool evaluating: false

  function evaluateAlerts() {
    if (root.evaluating) return
    root.evaluating = true
    var result = Model.evaluateAlerts(root.quotes, store.state.tickers, store.state.alertState, Date.now())

    if (!Model.alertStateEqual(result.nextAlertState, store.state.alertState)) {
      store.mutate(function (draft) { draft.alertState = result.nextAlertState })
    }
    root.evaluating = false

    if (result.fired.length > 0) {
      root.noteQueue = root.noteQueue.concat(result.fired)
      pumpNotes()
    }
  }

  function pumpNotes() {
    if (notifyProc.running || root.noteQueue.length === 0) return
    var note = root.noteQueue.shift()
    notifyProc.command = ["omarchy-notification-send", "--app-name", "Stocks",
      "-u", "normal", "-g", "", note.headline, note.body]
    notifyProc.running = true
  }

  Process {
    id: notifyProc
    onExited: root.pumpNotes()
  }
}
