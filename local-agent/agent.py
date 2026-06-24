#!/usr/bin/env python3
"""
fx-trade-scout (local) — one scan of Deriv R_75 using a LOCAL LLM.

The Python harness does the deterministic work (fetch data, reconcile open ideas, compute
levels, persist the log). The local model only makes the judgment and returns one JSON idea.

CLI:            python3 agent.py
Importable:     from agent import scan ; result = scan()   (raises DataError / LLMError)

Config from the environment (see config.env.example). Test toggles:
  LLM_MOCK=1      bypass the model, synthesize an idea from the data
  DERIV_SAMPLE=1  read sample_candles.json instead of the live Deriv feed
"""
import os, sys, json, re, time, pathlib, datetime, urllib.request, urllib.error

HERE = pathlib.Path(__file__).resolve().parent
LOG = HERE / "trade_log.json"
BRIEFS = HERE / "briefs"; BRIEFS.mkdir(exist_ok=True)
SYSTEM = (HERE / "system_prompt.txt").read_text()


def env(k, d=None): return os.environ.get(k, d)
def symbol(): return env("SYMBOL", "R_75")
def min_rr(): return float(env("MIN_RR", "1.5"))


class DataError(RuntimeError): pass
class LLMError(RuntimeError): pass


# ---------------------------------------------------------------- data
def fetch_candles(granularity, count):
    if env("DERIV_SAMPLE") == "1":
        return json.loads((HERE / "sample_candles.json").read_text())[str(granularity)]
    try:
        from websocket import create_connection  # pip install websocket-client
    except ImportError as e:
        raise DataError("websocket-client not installed (pip install -r requirements.txt)") from e
    try:
        app = env("DERIV_APP_ID", "1089")
        ws = create_connection(f"wss://ws.derivws.com/websockets/v3?app_id={app}", timeout=20)
        ws.send(json.dumps({"ticks_history": symbol(), "style": "candles",
                            "granularity": granularity, "count": count, "end": "latest"}))
        r = json.loads(ws.recv()); ws.close()
    except Exception as e:
        raise DataError(f"could not reach Deriv: {e}") from e
    if "error" in r:
        raise DataError(f"Deriv error: {r['error'].get('message')}")
    return r["candles"]


def summarize(candles):
    closes = [c["close"] for c in candles]
    highs = [c["high"] for c in candles]
    lows = [c["low"] for c in candles]
    last = candles[-1]
    n = len(closes)
    sma = sum(closes[-20:]) / min(20, n)
    rng = sum(h - l for h, l in zip(highs[-14:], lows[-14:])) / min(14, len(highs))
    return {
        "last_close": last["close"], "last_epoch": last["epoch"],
        "recent_high": max(highs[-50:]), "recent_low": min(lows[-50:]),
        "sma20": round(sma, 4), "avg_range14": round(rng, 4),
        "trend": "up" if last["close"] > sma else "down",
    }


# ---------------------------------------------------------------- log / memory
def load_log():
    if LOG.exists():
        return json.loads(LOG.read_text())
    return {"ideas": [], "track": {"closed": 0, "wins": 0, "losses": 0, "open": 0, "sum_r": 0.0}}


def save_log(log):
    LOG.write_text(json.dumps(log, indent=2))


def reconcile(log, candles_h1):
    """Deterministically check each open idea against price since it was logged."""
    for idea in log["ideas"]:
        if idea["status"] != "open":
            continue
        after = [c for c in candles_h1 if c["epoch"] >= idea["logged_epoch"]] or candles_h1[-1:]
        hi = max(c["high"] for c in after)
        lo = min(c["low"] for c in after)
        hit = None
        if idea["direction"] == "long":
            if lo <= idea["stop"]: hit = "stopped"
            elif hi >= idea["target"]: hit = "target"
        else:
            if hi >= idea["stop"]: hit = "stopped"
            elif lo <= idea["target"]: hit = "target"
        if hit:
            r = idea["rr"] if hit == "target" else -1.0
            idea.update(status="closed", result=hit, realized_r=round(r, 2), closed_at=int(time.time()))
            log["track"]["closed"] += 1
            log["track"]["wins" if hit == "target" else "losses"] += 1
            log["track"]["sum_r"] = round(log["track"]["sum_r"] + r, 2)
    log["track"]["open"] = sum(1 for i in log["ideas"] if i["status"] == "open")
    return log


# ---------------------------------------------------------------- LLM
def build_user_msg(s_h1, s_m5, log):
    open_ideas = [i for i in log["ideas"] if i["status"] == "open"]
    t = log["track"]
    hit = (t["wins"] / t["closed"] * 100) if t["closed"] else None
    return json.dumps({
        "instrument": symbol(), "min_risk_reward": min_rr(),
        "timeframe_1h": s_h1, "timeframe_5m": s_m5,
        "open_ideas": open_ideas,
        "track_record": {**t, "hit_rate_pct": round(hit, 1) if hit is not None else None},
        "instruction": "Return ONE JSON idea per the system spec. 'no setup' is a valid, common answer.",
    }, indent=2)


def mock_idea(s_h1):
    entry = s_h1["last_close"]; rng = s_h1["avg_range14"] or 1.0; m = min_rr()
    if s_h1["trend"] == "up":
        stop, target, direction = entry - rng, entry + m * rng, "long"
    else:
        stop, target, direction = entry + rng, entry - m * rng, "short"
    return {"setup": True, "direction": direction, "entry": round(entry, 4),
            "stop": round(stop, 4), "target": round(target, 4), "rr": m,
            "conviction": "medium", "invalidation": "trend flips against the SMA20",
            "rationale": "[MOCK] trend-following stub generated from the data, no model used."}


def call_llm(user_msg):
    if env("LLM_MOCK") == "1":
        return json.dumps(mock_idea(json.loads(user_msg)["timeframe_1h"]))
    base = env("LLM_BASE_URL", "http://localhost:11434/v1").rstrip("/")
    def post(body):
        req = urllib.request.Request(base + "/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json",
                                              "Authorization": f"Bearer {env('LLM_API_KEY', 'local')}"})
        with urllib.request.urlopen(req, timeout=180) as resp:
            return json.loads(resp.read())
    body = {"model": env("LLM_MODEL", "llama3.1"),
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user_msg}],
            "temperature": float(env("LLM_TEMPERATURE", "0.2")), "stream": False,
            "response_format": {"type": "json_object"}}
    try:
        d = post(body)
    except urllib.error.HTTPError:
        body.pop("response_format", None)  # some local servers reject it — retry once
        try:
            d = post(body)
        except Exception as e:
            raise LLMError(f"LLM request failed: {e}") from e
    except Exception as e:
        raise LLMError(f"could not reach the model at {base}: {e}") from e
    try:
        return d["choices"][0]["message"]["content"]
    except Exception as e:
        raise LLMError(f"unexpected LLM response shape: {e}") from e


def parse_idea(raw):
    txt = (raw or "").strip()
    try:
        obj = json.loads(txt)
    except Exception:
        m = re.search(r"\{.*\}", txt, re.S)
        if not m:
            return {"setup": False, "rationale": "model returned no parseable JSON", "_parse_error": True}
        try:
            obj = json.loads(m.group(0))
        except Exception:
            return {"setup": False, "rationale": "model JSON was malformed", "_parse_error": True}
    if not obj.get("setup"):
        return {"setup": False, "rationale": obj.get("rationale", "no high-probability setup")}
    try:
        entry, stop, target = float(obj["entry"]), float(obj["stop"]), float(obj["target"])
        rr = abs(target - entry) / abs(entry - stop)
    except Exception:
        return {"setup": False, "rationale": "setup missing valid entry/stop/target — stood aside", "_invalid": True}
    if obj.get("direction") not in ("long", "short") or rr + 1e-9 < min_rr():
        return {"setup": False, "rationale": f"setup rejected (rr={rr:.2f} < {min_rr()} or bad direction)", "_invalid": True}
    obj.update(rr=round(rr, 2), entry=entry, stop=stop, target=target)
    return obj


# ---------------------------------------------------------------- output
def append_idea(log, idea, s_h1):
    log["ideas"].append({
        "logged_epoch": s_h1["last_epoch"], "logged_iso": datetime.datetime.utcnow().isoformat() + "Z",
        "instrument": symbol(), "direction": idea["direction"], "entry": idea["entry"],
        "stop": idea["stop"], "target": idea["target"], "rr": idea["rr"],
        "conviction": idea.get("conviction"), "invalidation": idea.get("invalidation"),
        "rationale": idea.get("rationale"), "status": "open",
    })
    log["track"]["open"] = sum(1 for i in log["ideas"] if i["status"] == "open")


def write_brief(s_h1, s_m5, log, idea):
    sym = symbol()
    ts = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    t = log["track"]
    hit = f"{t['wins']}/{t['closed']} ({t['wins']/t['closed']*100:.0f}%)" if t["closed"] else "no closed trades yet"
    lines = [f"# {sym} brief — {ts}", "",
             f"- last close **{s_h1['last_close']}** (epoch {s_h1['last_epoch']})  ·  trend **{s_h1['trend']}**",
             f"- 1h structure: high {s_h1['recent_high']} · low {s_h1['recent_low']} · SMA20 {s_h1['sma20']} · avg14 range {s_h1['avg_range14']}",
             f"- track record: {hit} · sumR {t['sum_r']} · open {t['open']}", ""]
    if idea.get("setup"):
        lines += ["## Trade idea", "",
                  f"- **{idea['direction'].upper()}** {sym}",
                  f"- entry **{idea['entry']}** · stop **{idea['stop']}** · target **{idea['target']}** · R:R **{idea['rr']}**",
                  f"- conviction **{idea.get('conviction')}**",
                  f"- invalidation: {idea.get('invalidation')}",
                  f"- rationale: {idea.get('rationale')}", "",
                  "_Draft only — operator reviews and places any trade._"]
    else:
        lines += ["## No high-probability setup", "", f"- {idea.get('rationale')}"]
    closed_now = [i for i in log["ideas"] if i["status"] == "closed" and i.get("closed_at", 0) > time.time() - 3600]
    if closed_now:
        lines += ["", "## Reconciled this run"]
        for i in closed_now:
            lines.append(f"- {i['direction']} @ {i['entry']} → **{i['result']}** (R {i['realized_r']})")
    path = BRIEFS / f"{sym}-{ts}.md"
    path.write_text("\n".join(lines) + "\n")
    return path, "\n".join(lines) + "\n", closed_now


# ---------------------------------------------------------------- scan (importable) + CLI
def scan():
    """Run one scan. Returns a result dict. Raises DataError / LLMError on failure."""
    c_h1 = fetch_candles(3600, 200)
    c_m5 = fetch_candles(300, 200)
    s_h1, s_m5 = summarize(c_h1), summarize(c_m5)
    log = reconcile(load_log(), c_h1)
    raw = call_llm(build_user_msg(s_h1, s_m5, log))
    idea = parse_idea(raw)
    if idea.get("setup"):
        append_idea(log, idea, s_h1)
    path, brief_md, closed_now = write_brief(s_h1, s_m5, log, idea)
    save_log(log)
    verdict = f"{idea['direction'].upper()} (R:R {idea['rr']})" if idea.get("setup") else "no setup"
    return {"symbol": symbol(), "verdict": verdict, "setup": bool(idea.get("setup")), "idea": idea,
            "summary_h1": s_h1, "summary_m5": s_m5, "track": log["track"],
            "open_ideas": [i for i in log["ideas"] if i["status"] == "open"],
            "closed_now": closed_now, "brief_path": str(path), "brief_md": brief_md}


def main():
    print(f"[fx-trade-scout/local] scanning {symbol()} …")
    try:
        res = scan()
    except DataError as e:
        print(f"  data feed unavailable: {e}")
        print("  (set DERIV_SAMPLE=1 to test offline, or allow ws.derivws.com egress)")
        sys.exit(2)
    except LLMError as e:
        print(f"  LLM call failed: {e}")
        print(f"  check LLM_BASE_URL ({env('LLM_BASE_URL', 'http://localhost:11434/v1')}) and that the model is loaded")
        sys.exit(3)
    print(f"  verdict: {res['verdict']}")
    print(f"  brief:   {res['brief_path']}")
    print(f"  log:     {LOG}  (open {res['track']['open']} · closed {res['track']['closed']})")


if __name__ == "__main__":
    main()
