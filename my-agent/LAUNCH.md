# LAUNCH — fx-trade-scout

Everything is staged. Launch is a resumable sequence: each step skips objects already in `IDS.env`,
so if anything fails you just re-run `bash launch.sh`.

## 0. Put your key in place (the one manual step)

Create a key at **platform.claude.com → API keys** — note **which workspace** it belongs to (the
Console only shows that workspace's agents). Then either:

- paste it into `./.env` (already chmod 600, gitignored):  `ANTHROPIC_API_KEY=sk-ant-...`
- or `export ANTHROPIC_API_KEY=sk-ant-...` in your terminal.

The key never goes into chat. If it ever does, rotate it.

## 1. Launch (env → memory → agent → session → outcome kickoff)

```bash
bash launch.sh           # scans R_75 (Deriv V75) live — trades 24/7, no weekend gap
```

What it creates, in order (IDs saved to `IDS.env`):

| | Primitive | API |
|---|---|---|
| 📦 | environment `fx-trade-scout-env` (pip: websocket-client) | `POST /v1/environments` |
| 🧠 | memory store `fx-trade-log` (read_write) | `POST /v1/memory_stores` |
| 🤖 | agent `fx-trade-scout` (model `claude-opus-4-8`) | `POST /v1/agents` |
| ▶️ | session (memory attached) | `POST /v1/sessions` |
| 🎯 | outcome kickoff (task + rubric, `max_iterations: 3`) | `POST /v1/sessions/:id/events` |

## 2. Watch it

```bash
bash poll.sh             # status + outcome verdict (+ usage)
bash fetch-outputs.sh    # download fx-brief.md into ./outputs/
```
Console (your key's workspace): https://platform.claude.com/workspaces/default/agents

## 3. After it passes the rubric — put it on the clock

```bash
bash deploy.sh           # creates the hourly deployment + fires one manual test run
```
Cron `0 * * * *` · `UTC` — hourly, 24/7 (R_75 never closes).
The agent only no-ops if the Deriv data feed is unreachable.

## 4. Regression check before promoting any future version

```bash
bash evals/run-evals.sh  # one session per case, pinned to AGENT_VERSION
```

## Notes
- **No orders, ever, in v0** — the agent drafts; you place. Live order placement is v1 (see `NEXT-DIRECTIONS.md`).
- **Data**: v0 pulls R_75 candles from Deriv's public WebSocket (`app_id 1089`) — no credential.
  Adding your own Deriv API token (in a 🔐 vault) is the swap that unlocks gated live orders in v1.
