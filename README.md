# Stocks — an Omarchy shell plugin

A macOS Stocks-style widget for the [Omarchy](https://omarchy.org/) bar: a
rotating ticker pill, a watchlist popup with intraday sparklines, and
per-ticker price / percent-move alerts delivered as desktop notifications.

![screenshot](docs/screenshot.png)

## Features

- **Bar pill** — rotates through your watchlist showing `AAPL 315.34 ▲0.28%`,
  tinted green/red by the day's move.
- **Watchlist popup** — hero quote with a filled intraday sparkline, plus a
  row per ticker (price, mini sparkline, coloured 24h % badge). Click a row to
  make it the hero.
- **Add / remove tickers** from the popup. Symbols are validated against Yahoo
  Finance and their company name is fetched automatically. Works for equities,
  ETFs, indices (`^GSPC`), FX and crypto (`BTC-USD`).
- **Alerts**, per ticker: *rises above* / *falls below* a price, or *moves ±X%
  in a day*. Above/below alerts use a small hysteresis band so a price sitting
  on the line doesn't re-notify; percent-move fires once per calendar day.
- **Alerts run headless** — the check keeps running on a timer even when the
  popup is closed, because the plugin ships a `service` alongside the widget.

## Data source

Yahoo Finance's unauthenticated `v8/finance/spark` endpoint — no API key, one
batched request for the whole watchlist. It's an unofficial endpoint; if it
changes, only the URL and `parseSpark()` in `Model.js` need updating. Fetch
failures are non-fatal (last-good data stays on screen, with retry/backoff).

## Install

```bash
omarchy plugin add https://github.com/USER/omarchy-stocks.git
omarchy plugin enable tamas.stocks
```

The plugin lands **disabled** so you can read the code first (plugins run
unsandboxed inside `omarchy-shell`). `enable` drops the pill on the bar; move
it with `omarchy bar move tamas.stocks --section right`.

Update later with `omarchy plugin update tamas.stocks` (fast-forward pull, shows
a diff first).

### Hotkey (optional)

```
bind = SUPER, S, exec, omarchy-shell shell toggle tamas.stocks
```

## Configuration

State lives in `~/.local/state/omarchy/stocks.json` — the watchlist, alerts,
and two settings you can hand-edit:

| Key | Default | Meaning |
|-----|---------|---------|
| `settings.refreshSeconds` | `60` | quote poll interval (min 15) |
| `settings.rotateSeconds` | `5` | pill rotation interval (min 2) |

Everything else is edited from the popup.

## Development

The plugin directory is a plain git checkout, so hack on it in place.

```bash
node model.test.js        # pure-logic tests (state, parsing, alert engine)
omarchy restart shell     # reload after editing .qml — rescanPlugins does NOT
```

| File | Role |
|------|------|
| `manifest.json` | declares `bar-widget` + `service` |
| `BarWidget.qml` | the rotating bar pill |
| `Panel.qml` | the watchlist / alert-editor popup |
| `Service.qml` | headless singleton: quote polling + alert engine |
| `Model.js` | pure logic (Yahoo parsing, formatting, `evaluateAlerts`) |
| `StocksStore.qml` | `FileView` wrapper for the shared state file |
| `Sparkline.qml` | canvas price line |

## License

MIT — see [LICENSE](LICENSE).
