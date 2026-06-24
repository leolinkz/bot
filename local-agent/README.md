# fx-trade-scout — local-model edition

The same design as the Managed-Agents build, but it runs **entirely on your machine** against a
**local LLM** instead of Claude Managed Agents. (CMA is a hosted harness and cannot run a local
model, so this is a separate, self-contained implementation.)

```
  Deriv R_75 candles ─┐
  open ideas + log  ──┼─►  Python harness  ──►  your local LLM (judgment only)  ──►  trade idea / "no setup"
  computed levels  ───┘        │                                                          │
                               └────────────── reconcile + append + write brief ◄─────────┘
```

The **harness** does everything deterministic — fetch data, reconcile open ideas against price,
compute levels, persist `trade_log.json`. The **model** only decides "high-probability setup or
not" and returns one JSON idea. That division keeps it reliable even on small local models.

## 1. Install

```bash
cd local-agent
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp config.env.example config.env      # then edit LLM_BASE_URL / LLM_MODEL
```

## 2. Have a local model running (pick one)

| Runtime | Start it | Set in config.env |
|---|---|---|
| **Ollama** | `ollama serve` + `ollama pull llama3.1:8b` | `LLM_BASE_URL=http://localhost:11434/v1` · `LLM_MODEL=llama3.1:8b` |
| **LM Studio** | load a model → Local Server → Start | `LLM_BASE_URL=http://localhost:1234/v1` · `LLM_MODEL=<loaded id>` |
| **llama.cpp** | `./llama-server -m model.gguf --api` | `LLM_BASE_URL=http://localhost:8080/v1` |
| **vLLM** | `vllm serve <model>` | `LLM_BASE_URL=http://localhost:8000/v1` |

A capable instruct model (≥7–8B, e.g. `llama3.1:8b`, `qwen2.5:14b`) gives much better judgment than a tiny one.

## 3. Run

```bash
./run.sh                       # one scan: fetch → analyze → write brief → log
```

Output: a markdown brief in `briefs/`, and the running record in `trade_log.json`.

### Test without a model or network

```bash
LLM_MOCK=1 DERIV_SAMPLE=1 ./run.sh   # full pipeline, synthetic idea + bundled candles
DERIV_SAMPLE=1 ./run.sh              # real model, offline sample data
LLM_MOCK=1 ./run.sh                  # live Deriv data, no model needed
```

## 4. Run it on a schedule (the "always on" part)

Hourly via cron — `crontab -e`:

```
0 * * * *  cd /ABSOLUTE/PATH/local-agent && ./run.sh >> briefs/cron.log 2>&1
```

(R_75 trades 24/7, so there's no market-closed gap.)

## Guardrails (same as the managed build)

- **Draft-only.** It proposes entry/stop/target; **you** place any trade. No order code exists here.
- Every level comes from fetched data; the harness rejects any "setup" without a valid stop or with R:R below `MIN_RR`.
- `trade_log.json` is the memory + self-graded track record (hit rate, sum-R) that accrues over runs.

## Next directions

- **Live orders:** add a Deriv `proposal`/`buy` call behind a manual y/N confirm + stake cap (your Deriv API token).
- **More instruments:** add data sources and loop the scan over a symbol list.
- **Better evals:** replay historical bars through the harness to compare two models/prompts.
