// Minimal sanity tests for Model.js. Run: node model.test.js
var m = require("./Model.js")
var pass = 0, fail = 0
function ok(name, cond) {
  if (cond) { pass++; console.log("  ok  " + name) }
  else { fail++; console.log("FAIL  " + name) }
}

// ---- parseSpark (flat shape) ----
var flat = JSON.stringify({
  AAPL: { close: [100, null, 102, 104], chartPreviousClose: 100, previousClose: 100 }
})
var q = m.parseSpark(flat).AAPL
ok("parseSpark price = last non-null close", q.price === 104)
ok("parseSpark prevClose", q.prevClose === 100)
ok("parseSpark changePct", Math.abs(q.changePct - 4) < 1e-9)
ok("parseSpark spark drops nulls", q.spark.length === 3)
ok("parseSpark keeps currency", m.parseSpark(JSON.stringify({ AAPL: { close: [1], previousClose: 1, currency: "USD" } })).AAPL.currency === "USD")

// ---- parseSpark (nested shape) ----
var nested = JSON.stringify({
  spark: { result: [ { symbol: "MSFT", response: [ {
    meta: { chartPreviousClose: 200 },
    indicators: { quote: [ { close: [200, 190] } ] }
  } ] } ] }
})
var qm = m.parseSpark(nested).MSFT
ok("nested spark price", qm.price === 190)
ok("nested spark changePct negative", qm.changePct < 0)

// ---- parseChartMeta ----
ok("parseChartMeta good", m.parseChartMeta(JSON.stringify({
  chart: { result: [ { meta: { longName: "Apple Inc." } } ], error: null }
})).ok === true)
ok("parseChartMeta bad symbol", m.parseChartMeta(JSON.stringify({
  chart: { result: null, error: { code: "Not Found" } }
})).ok === false)
ok("parseChartMeta garbage", m.parseChartMeta("<html>").ok === false)

// ---- parseSearch ----
var search = m.parseSearch(JSON.stringify({ quotes: [
  { symbol: "SPCE", longname: "Virgin Galactic Holdings, Inc.", exchDisp: "NYSE", quoteType: "EQUITY" },
  { symbol: "UFO", shortname: "Procure Space ETF", exchange: "BTS", typeDisp: "ETF" },
  { symbol: "SPCE", shortname: "duplicate" },
  { longname: "missing symbol" }
] }))
ok("parseSearch returns quote matches", search.length === 2)
ok("parseSearch keeps company name", search[0].name === "Virgin Galactic Holdings, Inc.")
ok("parseSearch normalizes symbol", search[0].symbol === "SPCE")
ok("parseSearch keeps instrument type", search[1].type === "ETF")
ok("parseSearch rejects garbage", m.parseSearch("<html>").length === 0)
ok("parseSearch respects limit", m.parseSearch(JSON.stringify({ quotes: [{symbol:"A"},{symbol:"B"}] }), 1).length === 1)

// ---- state normalization ----
var st = m.normalizeState({
  tickers: [
    { symbol: "aapl", name: "Apple", alerts: [ { type: "above", value: "320" } ] },
    { symbol: "AAPL", name: "dup" },        // deduped
    { symbol: "", name: "empty" },          // dropped
    { symbol: "MSFT", alerts: [ { type: "bogus", value: 1 } ] } // bad alert dropped
  ],
  settings: { refreshSeconds: 2, rotateSeconds: 999 }, // clamped
  alertState: { orphan: { armed: false } }             // pruned
})
ok("dedupe + drop empties", st.tickers.length === 2)
ok("symbol uppercased", st.tickers[0].symbol === "AAPL")
ok("alert value coerced to number", st.tickers[0].alerts[0].value === 320)
ok("bad alert dropped", st.tickers[1].alerts.length === 0)
ok("refreshSeconds clamped up to 15", st.settings.refreshSeconds === 15)
ok("rotateSeconds clamped down to 60", st.settings.rotateSeconds === 60)
ok("orphan alertState pruned", Object.keys(st.alertState).length === 0)

// ---- alert editor defaults ----
ok("above alert starts above market", m.defaultAlertValue("above", { price: 100 }) === 101)
ok("below alert starts below market", m.defaultAlertValue("below", { price: 100 }) === 99)
ok("percentage alert defaults to 5%", m.defaultAlertValue("pctMove", { price: 100 }) === 5)
ok("missing quote has editable zero fallback", m.defaultAlertValue("above", null) === 0)

// ---- evaluateAlerts: above with hysteresis ----
var tickers = [ { symbol: "AAPL", name: "Apple", alerts: [
  { id: "x1", type: "above", value: 320, enabled: true }
] } ]
var now = Date.parse("2026-09-09T15:00:00Z")

// price below threshold -> nothing, armed
var r1 = m.evaluateAlerts({ AAPL: m.buildQuote(310, 300, []) }, tickers, {}, now)
ok("below threshold does not fire", r1.fired.length === 0)
ok("stays armed", r1.nextAlertState.x1.armed === true)

// price crosses above -> fires once, disarms
var r2 = m.evaluateAlerts({ AAPL: m.buildQuote(325, 300, []) }, tickers, r1.nextAlertState, now)
ok("crossing above fires", r2.fired.length === 1 && r2.fired[0].symbol === "AAPL")
ok("disarms after firing", r2.nextAlertState.x1.armed === false)

// still above -> does NOT fire again
var r3 = m.evaluateAlerts({ AAPL: m.buildQuote(330, 300, []) }, tickers, r2.nextAlertState, now)
ok("no repeat while still above", r3.fired.length === 0)

// small dip but within hysteresis band -> still disarmed
var r4 = m.evaluateAlerts({ AAPL: m.buildQuote(319, 300, []) }, tickers, r3.nextAlertState, now)
ok("inside hysteresis band stays disarmed", r4.nextAlertState.x1.armed === false)

// clear dip below band -> re-arms
var r5 = m.evaluateAlerts({ AAPL: m.buildQuote(300, 300, []) }, tickers, r4.nextAlertState, now)
ok("clears band and re-arms", r5.nextAlertState.x1.armed === true)

// ---- evaluateAlerts: pctMove once per day ----
var pctTickers = [ { symbol: "TSLA", name: "Tesla", alerts: [
  { id: "p1", type: "pctMove", value: 5, enabled: true }
] } ]
var big = { TSLA: m.buildQuote(120, 100, []) } // +20%
var p1 = m.evaluateAlerts(big, pctTickers, {}, now)
ok("pctMove fires on big move", p1.fired.length === 1)
var p2 = m.evaluateAlerts(big, pctTickers, p1.nextAlertState, now)
ok("pctMove does not re-fire same day", p2.fired.length === 0)
var nextDay = now + 24 * 3600 * 1000
var p3 = m.evaluateAlerts(big, pctTickers, p2.nextAlertState, nextDay)
ok("pctMove fires again next day", p3.fired.length === 1)

// ---- alertStateEqual ----
ok("alertStateEqual identical", m.alertStateEqual(r2.nextAlertState, r2.nextAlertState))
ok("alertStateEqual different", !m.alertStateEqual(r1.nextAlertState, r2.nextAlertState))

// ---- formatting + sparkline ----
ok("formatPrice 2dp", m.formatPrice(315.3456) === "315.35")
ok("formatPrice small 4dp", m.formatPrice(0.01234) === "0.0123")
ok("formatSignedPct", m.formatSignedPct(-1.234) === "−1.23%")
ok("formatUpdateTime empty", m.formatUpdateTime(0) === "Not updated yet")
ok("formatUpdateTime has clock", m.formatUpdateTime(now).indexOf("Updated ") === 0)
ok("rotationLabel", m.rotationLabel({ symbol: "AAPL" }, m.buildQuote(100, 98, [])).indexOf("AAPL") === 0)
var pts = m.sparklinePoints([1, 2, 3, 4], 100, 10, 0)
ok("sparklinePoints count", pts.length === 4)
ok("sparklinePoints x spans width", pts[0].x === 0 && pts[3].x === 100)
ok("sparklinePoints y inverted (min at bottom)", pts[0].y === 10 && pts[3].y === 0)
ok("sparklinePoints too few", m.sparklinePoints([1], 100, 10, 0).length === 0)

console.log("\n" + pass + " passed, " + fail + " failed")
process.exit(fail ? 1 : 0)
