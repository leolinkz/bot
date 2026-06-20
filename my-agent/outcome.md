# Outcome — fx-trade-scout's definition of done

The platform grades every run against these binary criteria (`rubric.content`, `max_iterations: 3`).

1. `fx-brief.md` exists and has a section for **R_75 (Volatility 75 Index)** — either a trade idea or an explicit "no high-probability setup" with watch levels.
2. Every price or level cited is **fetched from Deriv this run and tagged with its timestamp** (epoch/candle time); no un-sourced or invented numbers.
3. Any emitted trade idea states all of: **direction, entry, stop, target, and the resulting risk:reward (≥ 1.5:1)**.
4. Any emitted trade idea states a **one-line invalidation condition** and a **conviction label** (medium/high).
5. **Prior open ideas from the memory store are reconciled first** — each marked hit-target / stopped-out / still-open with the price evidence — before any new idea is proposed.
6. **No order is placed** and nothing is sent to an external system — the output is a draft brief only.
