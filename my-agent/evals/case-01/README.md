# eval case-01 — the regression baseline

Trade setups are fresh data, so there's no hand-labeled "golden answer" to test against.
Instead: **today's first verified run output** gets saved here as `expected.md` at close.

That becomes the regression check — before promoting any new agent version (v2, v3…) to the
scheduled deployment, re-run it against this baseline and confirm the rubric verdict still holds.

The deeper, accruing eval is the **self-graded track record** inside the `fx-trade-log` memory
store: hit rate and average R over real runs.
