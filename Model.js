// Pure logic for the Stocks widget: state (de)serialization, Yahoo Finance
// response parsing, formatting, sparkline geometry, and alert evaluation.
//
// Everything here is Qt- and locale-free so it can be unit-tested under node
// (see the block at the bottom of this file), mirroring how the clock and
// weather plugins split their math out of QML.

// Hysteresis band: an above/below alert only re-arms once price has pulled
// back this far past the threshold, so a value hovering on the line does not
// fire a notification every refresh.
var REARM_MARGIN = 0.005 // 0.5%

var ALERT_TYPES = ["above", "below", "pctMove"]

// ---------------------------------------------------------------- state ----

function defaultSettings() {
  return { refreshSeconds: 60, rotateSeconds: 5 }
}

function defaultState() {
  return { version: 1, tickers: [], settings: defaultSettings(), alertState: {} }
}

function genId() {
  return "a" + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
}

function clampInt(value, min, max, fallback) {
  var n = parseInt(value, 10)
  if (!isFinite(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function normalizeSettings(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  return {
    refreshSeconds: clampInt(s.refreshSeconds, 15, 3600, 60),
    rotateSeconds: clampInt(s.rotateSeconds, 2, 60, 5)
  }
}

function normalizeAlert(raw) {
  if (!raw || typeof raw !== "object") return null
  var type = String(raw.type || "")
  if (ALERT_TYPES.indexOf(type) === -1) return null
  var value = Number(raw.value)
  if (!isFinite(value)) return null
  if (type === "pctMove") value = Math.abs(value)
  return {
    id: String(raw.id || genId()),
    type: type,
    value: value,
    enabled: raw.enabled !== false
  }
}

function normalizeTicker(raw) {
  if (!raw || typeof raw !== "object") return null
  var symbol = String(raw.symbol || "").trim().toUpperCase()
  if (!symbol) return null
  var alerts = []
  if (Array.isArray(raw.alerts)) {
    for (var i = 0; i < raw.alerts.length; i++) {
      var a = normalizeAlert(raw.alerts[i])
      if (a) alerts.push(a)
    }
  }
  return { symbol: symbol, name: String(raw.name || ""), alerts: alerts }
}

function liveAlertIds(tickers) {
  var ids = {}
  for (var i = 0; i < (tickers || []).length; i++)
    for (var j = 0; j < (tickers[i].alerts || []).length; j++)
      ids[tickers[i].alerts[j].id] = true
  return ids
}

function normalizeAlertRecord(raw) {
  var r = raw && typeof raw === "object" ? raw : {}
  return {
    armed: r.armed !== false,
    lastFired: Number(r.lastFired) || 0,
    lastFiredDay: String(r.lastFiredDay || "")
  }
}

function normalizeState(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  var tickers = []
  var seen = {}
  if (Array.isArray(s.tickers)) {
    for (var i = 0; i < s.tickers.length; i++) {
      var t = normalizeTicker(s.tickers[i])
      if (t && !seen[t.symbol]) { seen[t.symbol] = true; tickers.push(t) }
    }
  }
  var live = liveAlertIds(tickers)
  var rawAlertState = s.alertState && typeof s.alertState === "object" ? s.alertState : {}
  var alertState = {}
  for (var id in rawAlertState)
    if (live[id]) alertState[id] = normalizeAlertRecord(rawAlertState[id])
  return {
    version: 1,
    tickers: tickers,
    settings: normalizeSettings(s.settings),
    alertState: alertState
  }
}

function parseState(text) {
  try {
    return normalizeState(JSON.parse(String(text || "")))
  } catch (e) {
    return defaultState()
  }
}

function symbolList(state) {
  return ((state && state.tickers) || []).map(function (t) { return t.symbol })
}

function findTicker(state, symbol) {
  var sym = String(symbol || "").toUpperCase()
  var list = (state && state.tickers) || []
  for (var i = 0; i < list.length; i++) if (list[i].symbol === sym) return list[i]
  return null
}

// ------------------------------------------------- Yahoo Finance parsing ----

function cleanNumbers(arr) {
  var out = []
  if (!Array.isArray(arr)) return out
  for (var i = 0; i < arr.length; i++) {
    if (arr[i] === null || arr[i] === undefined) continue
    var n = Number(arr[i])
    if (isFinite(n)) out.push(n)
  }
  return out
}

function buildQuote(price, prev, spark) {
  var change = null
  var changePct = null
  if (price !== null && isFinite(price) && isFinite(prev) && prev !== 0) {
    change = price - prev
    changePct = (change / prev) * 100
  }
  return {
    price: (price !== null && isFinite(price)) ? price : null,
    prevClose: isFinite(prev) ? prev : null,
    change: change,
    changePct: changePct,
    spark: spark || []
  }
}

function quoteFromFlatSpark(entry) {
  var closes = cleanNumbers(entry.close)
  var prev = Number(entry.chartPreviousClose)
  if (!isFinite(prev)) prev = Number(entry.previousClose)
  var price = closes.length ? closes[closes.length - 1] : (isFinite(prev) ? prev : null)
  return buildQuote(price, prev, closes)
}

function quoteFromNestedSpark(response) {
  var closes = []
  var ind = response && response.indicators
  if (ind && Array.isArray(ind.quote) && ind.quote[0])
    closes = cleanNumbers(ind.quote[0].close)
  var meta = response && response.meta
  var prev = meta ? Number(meta.chartPreviousClose) : NaN
  if (!isFinite(prev) && meta) prev = Number(meta.previousClose)
  var price = closes.length
    ? closes[closes.length - 1]
    : (meta && isFinite(Number(meta.regularMarketPrice)) ? Number(meta.regularMarketPrice) : (isFinite(prev) ? prev : null))
  return buildQuote(price, prev, closes)
}

// Accepts both spark response shapes: the flat `{ "AAPL": { close, ... } }`
// map and the nested `{ spark: { result: [ { symbol, response: [...] } ] } }`.
function parseSpark(text) {
  var out = {}
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return out }
  if (!data || typeof data !== "object") return out

  if (data.spark && Array.isArray(data.spark.result)) {
    for (var i = 0; i < data.spark.result.length; i++) {
      var row = data.spark.result[i]
      var sym = row && row.symbol
      var response = row && Array.isArray(row.response) ? row.response[0] : null
      if (!sym || !response) continue
      out[String(sym).toUpperCase()] = quoteFromNestedSpark(response)
    }
    return out
  }

  for (var key in data) {
    var entry = data[key]
    if (!entry || typeof entry !== "object" || !("close" in entry)) continue
    out[String(key).toUpperCase()] = quoteFromFlatSpark(entry)
  }
  return out
}

// Pull a display name (and validity) out of a v8/finance/chart response.
function parseChartMeta(text) {
  try {
    var data = JSON.parse(String(text || ""))
    var chart = data && data.chart
    if (!chart || chart.error) return { ok: false, name: "" }
    var result = chart.result && chart.result[0]
    var meta = result && result.meta
    if (!meta) return { ok: false, name: "" }
    return { ok: true, name: String(meta.longName || meta.shortName || "") }
  } catch (e) {
    return { ok: false, name: "" }
  }
}

// ------------------------------------------------------------ formatting ----

function formatPrice(value) {
  if (value === null || value === undefined || !isFinite(value)) return "—"
  var abs = Math.abs(value)
  var digits = abs >= 1000 ? 2 : (abs >= 1 ? 2 : 4)
  return Number(value).toLocaleString !== undefined
    ? Number(value).toFixed(digits)
    : String(value)
}

function formatSignedPct(value) {
  if (value === null || value === undefined || !isFinite(value)) return "—"
  return (value >= 0 ? "+" : "−") + Math.abs(value).toFixed(2) + "%"
}

function formatSignedChange(value) {
  if (value === null || value === undefined || !isFinite(value)) return "—"
  return (value >= 0 ? "+" : "−") + formatPrice(Math.abs(value))
}

function direction(value) {
  if (value === null || value === undefined || !isFinite(value) || value === 0) return 0
  return value > 0 ? 1 : -1
}

function arrow(value) {
  var d = direction(value)
  if (d > 0) return "▲"
  if (d < 0) return "▼"
  return "·"
}

// Bar-pill label, e.g. "AAPL 315.34 ▲0.28%".
function rotationLabel(ticker, quote) {
  if (!ticker) return ""
  if (!quote || quote.price === null)
    return ticker.symbol + "  —"
  var pct = (quote.changePct === null || !isFinite(quote.changePct))
    ? ""
    : "  " + arrow(quote.changePct) + Math.abs(quote.changePct).toFixed(2) + "%"
  return ticker.symbol + "  " + formatPrice(quote.price) + pct
}

// One-line summary for the right-click notification.
function watchlistSummary(tickers, quotes) {
  var parts = []
  for (var i = 0; i < (tickers || []).length; i++) {
    var t = tickers[i]
    var q = quotes ? quotes[t.symbol] : null
    if (!q || q.price === null) { parts.push(t.symbol + " —"); continue }
    parts.push(t.symbol + " " + formatPrice(q.price) + " " + formatSignedPct(q.changePct))
  }
  return parts.length ? parts.join("    ") : "No tickers yet"
}

// ------------------------------------------------------ sparkline geometry ----

function sparklinePoints(values, width, height, pad) {
  pad = pad || 0
  var v = cleanNumbers(values)
  if (v.length < 2) return []
  var min = Math.min.apply(null, v)
  var max = Math.max.apply(null, v)
  var span = (max - min) || 1
  var innerW = Math.max(1, width - pad * 2)
  var innerH = Math.max(1, height - pad * 2)
  var pts = []
  for (var i = 0; i < v.length; i++) {
    pts.push({
      x: pad + (i / (v.length - 1)) * innerW,
      y: pad + innerH - ((v[i] - min) / span) * innerH
    })
  }
  return pts
}

// ----------------------------------------------------------- alert engine ----

function dayKey(ms) {
  var d = new Date(ms)
  return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate()
}

function alertLabel(alert) {
  if (!alert) return ""
  if (alert.type === "above") return "Above " + formatPrice(alert.value)
  if (alert.type === "below") return "Below " + formatPrice(alert.value)
  return "Moves ±" + Math.abs(alert.value) + "% in a day"
}

function makeNotification(ticker, alert, quote, kind) {
  var sym = ticker.symbol
  var price = formatPrice(quote.price)
  if (kind === "above") {
    return {
      symbol: sym, alertId: alert.id,
      headline: sym + "  ▲ " + price,
      body: (ticker.name || sym) + " rose above your " + formatPrice(alert.value) + " alert"
    }
  }
  if (kind === "below") {
    return {
      symbol: sym, alertId: alert.id,
      headline: sym + "  ▼ " + price,
      body: (ticker.name || sym) + " fell below your " + formatPrice(alert.value) + " alert"
    }
  }
  return {
    symbol: sym, alertId: alert.id,
    headline: sym + "  " + arrow(quote.changePct) + " " + Math.abs(quote.changePct).toFixed(2) + "%",
    body: (ticker.name || sym) + " moved more than " + Math.abs(alert.value) + "% today — now " + price
  }
}

// Evaluate every enabled alert against the latest quotes. Returns the list of
// notifications to fire now plus the next alert-state map (armed flags and
// last-fired stamps) to persist.
function evaluateAlerts(quotes, tickers, alertState, nowMs) {
  var fired = []
  var next = {}
  var prev = alertState || {}
  for (var id in prev) next[id] = normalizeAlertRecord(prev[id])

  for (var i = 0; i < (tickers || []).length; i++) {
    var ticker = tickers[i]
    var quote = quotes ? quotes[ticker.symbol] : null
    for (var j = 0; j < (ticker.alerts || []).length; j++) {
      var alert = ticker.alerts[j]
      if (!alert || alert.enabled === false) continue
      var st = next[alert.id] || { armed: true, lastFired: 0, lastFiredDay: "" }

      if (quote && quote.price !== null && isFinite(quote.price)) {
        if (alert.type === "above") {
          if (quote.price >= alert.value) {
            if (st.armed) {
              fired.push(makeNotification(ticker, alert, quote, "above"))
              st.armed = false
              st.lastFired = nowMs
            }
          } else if (quote.price < alert.value * (1 - REARM_MARGIN)) {
            st.armed = true
          }
        } else if (alert.type === "below") {
          if (quote.price <= alert.value) {
            if (st.armed) {
              fired.push(makeNotification(ticker, alert, quote, "below"))
              st.armed = false
              st.lastFired = nowMs
            }
          } else if (quote.price > alert.value * (1 + REARM_MARGIN)) {
            st.armed = true
          }
        } else if (alert.type === "pctMove") {
          var day = dayKey(nowMs)
          var moved = quote.changePct !== null && isFinite(quote.changePct)
            && Math.abs(quote.changePct) >= Math.abs(alert.value)
          if (moved && st.lastFiredDay !== day) {
            fired.push(makeNotification(ticker, alert, quote, "pctMove"))
            st.lastFiredDay = day
            st.lastFired = nowMs
          }
        }
      }

      next[alert.id] = st
    }
  }

  var live = liveAlertIds(tickers)
  var pruned = {}
  for (var k in next) if (live[k]) pruned[k] = next[k]
  return { fired: fired, nextAlertState: pruned }
}

function alertStateEqual(a, b) {
  a = a || {}
  b = b || {}
  var ka = Object.keys(a)
  var kb = Object.keys(b)
  if (ka.length !== kb.length) return false
  for (var i = 0; i < ka.length; i++) {
    var key = ka[i]
    if (!(key in b)) return false
    var x = normalizeAlertRecord(a[key])
    var y = normalizeAlertRecord(b[key])
    if (x.armed !== y.armed) return false
    if (x.lastFired !== y.lastFired) return false
    if (x.lastFiredDay !== y.lastFiredDay) return false
  }
  return true
}

// ------------------------------------------------------------ node export ----

if (typeof module !== "undefined") {
  module.exports = {
    REARM_MARGIN: REARM_MARGIN,
    ALERT_TYPES: ALERT_TYPES,
    defaultState: defaultState,
    defaultSettings: defaultSettings,
    genId: genId,
    normalizeState: normalizeState,
    parseState: parseState,
    symbolList: symbolList,
    findTicker: findTicker,
    parseSpark: parseSpark,
    parseChartMeta: parseChartMeta,
    buildQuote: buildQuote,
    formatPrice: formatPrice,
    formatSignedPct: formatSignedPct,
    formatSignedChange: formatSignedChange,
    direction: direction,
    arrow: arrow,
    rotationLabel: rotationLabel,
    watchlistSummary: watchlistSummary,
    sparklinePoints: sparklinePoints,
    dayKey: dayKey,
    alertLabel: alertLabel,
    evaluateAlerts: evaluateAlerts,
    alertStateEqual: alertStateEqual
  }
}
