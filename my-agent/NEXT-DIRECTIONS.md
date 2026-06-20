# Next directions — the version rail

v0 is live decision-support on **Deriv R_75 (Volatility 75 Index)**: it scans 24/7, grades its own
past calls, and drafts trade ideas you review. Everything below is a **planned release**, not a cut.

---

## v1 — Live order placement through Deriv (the headline)

- **What:** the agent can actually place the trade it drafts, on your Deriv account.
- **Why it's v1, not v0:** real money. The recommendation is to earn trust on the track record in
  `fx-trade-log` first — a default, not a hard limit. Pull it forward whenever you want.
- **How:** register your own Deriv **app_id + API token**, store the token in a 🔐 vault, and let the
  agent place via Deriv's `proposal`/`buy` API — gated with an `always_ask` permission policy so
  nothing fires without your approval, plus a hard stake cap. Safer first step: point it at a Deriv
  **demo account** and let it trade freely there before the real one.

## v1 — Add gold (XAU/USD) and EUR/USD back as instruments

- **What:** the original two pairs, alongside R_75.
- **Why later:** parked while we prove the engine on the 24/7 instrument.
- **How:** add their data source (a broker MCP connector with a vault credential, or web quotes) and
  extend the scan + rubric to cover all instruments in one brief.

## v2 — Real-time instead of hourly polling

- **What:** react the moment a setup forms, instead of on the next hourly scan.
- **Why later:** polling is the pragmatic v0; true real-time needs a push source.
- **How:** subscribe to Deriv's tick stream and trigger `POST /sessions` or `/deployments/<id>/run`
  on a signal (event-driven), or simply tighten the deployment cron to a 15-minute interval.

## v3 — Backtest harness · network lockdown · trade-log dashboard

- **What:** score a strategy change before it goes live; lock the agent's network; give yourself a UI.
- **Why later:** tooling / hardening once the edge is proven.
- **How:** replay historical R_75 bars through a pinned agent version and compare; environment
  `networking: limited` + `allowed_hosts` (Deriv host only); a generated results UI over the log.

## always — Re-run evals before promoting a new version

- Run `evals/run-evals.sh` against any new agent version and confirm the rubric verdict still holds
  on `case-01` before pointing the scheduled deployment at it.
