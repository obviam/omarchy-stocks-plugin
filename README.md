# Stocks — an Omarchy shell plugin

A macOS Stocks-style widget for the [Omarchy](https://omarchy.org/) bar: a
rotating ticker pill, a watchlist popup with intraday sparklines, and
per-ticker price / percent-move alerts delivered as desktop notifications.

## Features

- **Bar pill** — rotates through your watchlist showing `AAPL 315.34 ▲0.28%`,
  tinted green/red by the day's move.
- **Watchlist popup** — hero quote with a filled intraday sparkline, plus a
  row per ticker (price, mini sparkline, coloured daily-change badge). Click a row to
  make it the hero.
- **Add / remove tickers** from the popup. Symbols are validated against Yahoo
  Finance and their company name is fetched automatically. Works for equities,
  ETFs, indices (`^GSPC`), FX and crypto (`BTC-USD`).
- **Alerts**, per ticker: *rises above* / *falls below* a price, or *moves ±X%
  in a day*. Above/below alerts use a small hysteresis band so a price sitting
  on the line doesn't re-notify; percent-move fires once per calendar day.
- **Alerts run headless** — the check keeps running on a timer even when the
  popup is closed, because the plugin ships a `service` alongside the widget.
- **Clear data status** — the popup shows refresh progress, last update time,
  and when cached prices are being shown after a connection failure.
- **Watchlist controls** — reorder symbols in the popup and undo accidental
  removals.

## Data source

Yahoo Finance's unauthenticated `v8/finance/spark` endpoint — no API key, one
batched request for the whole watchlist. It's an unofficial endpoint; if it
changes, only the URL and `parseSpark()` in `Model.js` need updating. Fetch
failures are non-fatal (last-good data stays on screen, with retry/backoff).

## Install

```bash
omarchy plugin add <repository-url>
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

## Controls

- Left-click the bar pill to open or close the popup.
- Middle-click it to refresh quotes immediately.
- Right-click it for a watchlist summary notification.
- In the popup, use `[` / `]` or the arrow keys to change the selected ticker,
  `a` or `+` to focus Add, and `r` to refresh.

## Configuration

State lives in `~/.local/state/omarchy/stocks.json` — the watchlist, alerts,
and two settings available in the popup:

| Key | Default | Meaning |
|-----|---------|---------|
| `settings.refreshSeconds` | `60` | quote poll interval (min 15) |
| `settings.rotateSeconds` | `5` | pill rotation interval (min 2) |

The file can still be edited by hand while troubleshooting. Invalid setting
values are clamped to the ranges above when state is loaded.

## Quote and alert behavior

Prices are labelled with their currency, exchange, and market state when Yahoo
provides that metadata. Change values are measured from the previous close,
not over a rolling 24-hour window.

New price alerts start 1% away from the latest quote so creating one does not
immediately notify. Changing an alert type resets its value to a useful default:
1% away for price thresholds or 5% for a daily percentage move.

Alerts are evaluated only while `omarchy-shell` is running. They are not
exchange-hosted alerts and cannot notify while the computer is off.

## Troubleshooting

- **“Couldn’t reach quote service”** — check internet access and that `curl` is
  installed, then press `r` to retry.
- **“Unknown symbol”** — enter the Yahoo Finance symbol, including suffixes
  such as `.L` for many London listings or `-USD` for crypto pairs.
- **“Quotes unavailable”** — retries were exhausted. Last-known prices remain
  visible and are explicitly marked as stale.
- If the widget does not reload after development changes, run
  `omarchy restart shell`.

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
