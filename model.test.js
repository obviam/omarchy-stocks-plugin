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

// ---- parseChart + periodChange ----
var chart = m.parseChart(JSON.stringify({
  chart: { error: null, result: [ {
    meta: { longName: "Apple Inc.", currency: "USD", exchangeName: "NMS", chartPreviousClose: 100 },
    indicators: { quote: [ { close: [100, null, 110, 120] } ] }
  } ] }
}))
ok("parseChart ok", chart.ok === true)
ok("parseChart drops null closes", chart.closes.length === 3)
ok("parseChart keeps name", chart.name === "Apple Inc.")
ok("parseChart error response", m.parseChart(JSON.stringify({ chart: { error: { code: "Not Found" } } })).ok === false)
ok("parseChart garbage", m.parseChart("<html>").ok === false)
var pc = m.periodChange([100, 90, 125])
ok("periodChange absolute", pc.change === 25)
ok("periodChange percent", pc.changePct === 25)
ok("periodChange too few points", m.periodChange([100]).changePct === null)

// ---- chart range specs ----
ok("chartRangeSpec known", m.chartRangeSpec("1mo").interval === "1d")
ok("chartRangeSpec falls back to 1d", m.chartRangeSpec("bogus").value === "1d")
ok("chartRangeLabel", m.chartRangeLabel("5y") === "5Y")
ok("normalizeChartRange keeps valid", m.normalizeChartRange("3mo") === "3mo")
ok("normalizeChartRange rejects invalid", m.normalizeChartRange("42y") === "1d")
ok("default settings carry chartRange", m.defaultSettings().chartRange === "1d")
ok("normalizeState defaults chartRange", m.normalizeState({}).settings.chartRange === "1d")
ok("normalizeState keeps chosen chartRange", m.normalizeState({ settings: { chartRange: "1y" } }).settings.chartRange === "1y")
ok("chart ranges include a distinct 1W", m.chartRangeSpec("1w").days === 7)
ok("1W query spans seven calendar days", m.chartQuery("1w", 1000000) === "period1=395200&period2=1000000&interval=15m")
ok("fixed chart query uses range", m.chartQuery("3mo", 1000000) === "range=3mo&interval=1d")

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

// ---- bounded remote fetch ----
ok("readBounded passes text under the cap", m.readBounded("abc", 10) === "abc")
ok("readBounded rejects text at the cap", m.readBounded("abcdefghij", 10) === null)
ok("readBounded rejects text over the cap", m.readBounded("abcdefghijk", 10) === null)
ok("readBounded treats missing text as empty, under any positive cap", m.readBounded(undefined, 10) === "")

var cmd = m.curlCommand("https://example.com/x?a=1", 7, 2048)
ok("curlCommand runs through sh -c", cmd[0] === "sh" && cmd[1] === "-c")
ok("curlCommand pipes curl into head -c", /curl .* \| head -c/.test(cmd[2]))
ok("curlCommand never inlines the URL into the script", cmd[2].indexOf("example.com") === -1)
ok("curlCommand passes the URL as a positional arg instead", cmd.indexOf("https://example.com/x?a=1") !== -1)
ok("curlCommand carries the requested max-time", cmd.indexOf("7") !== -1)
ok("curlCommand carries the requested byte cap", cmd.indexOf("2048") !== -1)

ok("capString passes short values through", m.capString("AAPL", 10) === "AAPL")
ok("capString truncates long values", m.capString("x".repeat(500), 10).length === 10)
ok("capString treats missing values as empty", m.capString(undefined, 10) === "")

// A spark response with a wildly oversized close series and metadata
// strings still comes back capped, not just truncated by luck.
var hugeCloses = []
for (var hc = 0; hc < m.MAX_SERIES_POINTS + 500; hc++) hugeCloses.push(hc)
var hugeSpark = JSON.stringify({
  AAPL: { close: hugeCloses, previousClose: 0, currency: "x".repeat(1000) }
})
var hugeQuote = m.parseSpark(hugeSpark).AAPL
ok("parseSpark caps retained series length", hugeQuote.spark.length === m.MAX_SERIES_POINTS)
ok("parseSpark keeps the most recent points", hugeQuote.spark[hugeQuote.spark.length - 1] === hugeCloses[hugeCloses.length - 1])
ok("parseSpark caps retained field length", hugeQuote.currency.length === m.MAX_FIELD_CHARS)

// A spark response with far more symbols than any real watchlist is capped
// by record count, not just left to grow unbounded.
var manySymbols = {}
for (var ms = 0; ms < m.MAX_QUOTE_SYMBOLS + 50; ms++)
  manySymbols["SYM" + ms] = { close: [1], previousClose: 1 }
ok("parseSpark caps retained symbol count", Object.keys(m.parseSpark(JSON.stringify(manySymbols))).length === m.MAX_QUOTE_SYMBOLS)

// A response `head -c` had to truncate is rejected before JSON.parse, not
// handed to it and caught.
var oversizedText = "x".repeat(m.MAX_SEARCH_BYTES + 1)
ok("parseSearch rejects an over-cap response outright", m.parseSearch(oversizedText).length === 0)
ok("parseChart rejects an over-cap response outright", m.parseChart("x".repeat(m.MAX_CHART_BYTES + 1)).ok === false)
ok("parseChartMeta rejects an over-cap response outright", m.parseChartMeta("x".repeat(m.MAX_CHART_BYTES + 1)).ok === false)

console.log("\n" + pass + " passed, " + fail + " failed")
process.exit(fail ? 1 : 0)
