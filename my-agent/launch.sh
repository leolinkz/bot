#!/usr/bin/env bash
# Resumable launch for fx-trade-scout. Each step reads IDS.env and skips objects
# that already exist, so a failed run can be re-run without creating duplicates.
set -euo pipefail
cd "$(dirname "$0")"

# --- creds ---
set -a; source .env; set +a
if [ -z "${ANTHROPIC_API_KEY:-}" ] || [[ "$ANTHROPIC_API_KEY" == REPLACE_* ]]; then
  echo "ERROR: put your real key in $(pwd)/.env first (ANTHROPIC_API_KEY=sk-ant-...)"; exit 1
fi
BASE=https://api.anthropic.com/v1
H=(-H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
   -H "anthropic-beta: managed-agents-2026-04-01" -H "content-type: application/json")

touch IDS.env; set -a; source IDS.env; set +a
save_id(){ echo "$1=$2" >> IDS.env; export "$1=$2"; echo "  ✅ $1=$2"; }
jget(){ python3 -c "import json; d=json.JSONDecoder(strict=False).decode(open('$1').read()); print(d$2)"; }

# Which kickoff prompt to use: standard scan (default) or weekend prep.
KICK_FILE="${KICK_FILE:-first_prompt.txt}"

# --- model pick: newest Opus-class ---
MODEL="${MODEL:-claude-opus-4-8}"
echo "Model: $MODEL"

# --- 1. environment ---
if [ -z "${ENV_ID:-}" ]; then
  echo "Creating 📦 environment..."
  code=$(curl -sS -o /tmp/env.json -w '%{http_code}' "$BASE/environments" "${H[@]}" \
    -d '{"name":"fx-trade-scout-env","config":{"type":"cloud","networking":{"type":"unrestricted"},"packages":{"pip":["websocket-client"]}}}')
  [ "$code" = "200" ] || { echo "env create failed ($code):"; cat /tmp/env.json; exit 1; }
  save_id ENV_ID "$(jget /tmp/env.json "['id']")"
else echo "📦 ENV_ID exists ($ENV_ID) — skip"; fi

# --- 2. memory store ---
if [ -z "${MEMSTORE_ID:-}" ]; then
  echo "Creating 🧠 memory store fx-trade-log..."
  code=$(curl -sS -o /tmp/mem.json -w '%{http_code}' "$BASE/memory_stores" "${H[@]}" \
    -d '{"name":"fx-trade-log","description":"Every trade idea this agent drafts (pair, direction, entry/stop/target, timestamp, status) plus a running track record (count, hit rate, average R). The agent reads this first each run to grade past calls and adapt."}')
  [ "$code" = "200" ] || { echo "memory create failed ($code):"; cat /tmp/mem.json; exit 1; }
  save_id MEMSTORE_ID "$(jget /tmp/mem.json "['id']")"
else echo "🧠 MEMSTORE_ID exists ($MEMSTORE_ID) — skip"; fi

# --- 3. agent (inject the picked model into agent.json) ---
if [ -z "${AGENT_ID:-}" ]; then
  echo "Creating 🤖 agent fx-trade-scout..."
  python3 -c "import json; a=json.load(open('agent.json')); a['model']={'id':'$MODEL'}; json.dump(a,open('/tmp/agent_payload.json','w'))"
  code=$(curl -sS -o /tmp/agent.json -w '%{http_code}' "$BASE/agents" "${H[@]}" -d @/tmp/agent_payload.json)
  [ "$code" = "200" ] || { echo "agent create failed ($code):"; cat /tmp/agent.json; exit 1; }
  save_id AGENT_ID "$(jget /tmp/agent.json "['id']")"
  save_id AGENT_VERSION "$(jget /tmp/agent.json "['version']")"
else echo "🤖 AGENT_ID exists ($AGENT_ID) — skip"; fi

# --- 4. session (attach the memory store) ---
if [ -z "${SESSION_ID:-}" ]; then
  echo "Creating ▶️ session..."
  python3 -c "
import json
body={'agent':'$AGENT_ID','environment_id':'$ENV_ID','title':'fx-trade-scout first run',
 'resources':[{'type':'memory_store','memory_store_id':'$MEMSTORE_ID','access':'read_write',
   'instructions':'Your trade log. Read it first each run to reconcile open ideas and update the track record; append every new idea.'}]}
json.dump(body,open('/tmp/sess_payload.json','w'))"
  code=$(curl -sS -o /tmp/sess.json -w '%{http_code}' "$BASE/sessions" "${H[@]}" -d @/tmp/sess_payload.json)
  [ "$code" = "200" ] || { echo "session create failed ($code):"; cat /tmp/sess.json; exit 1; }
  save_id SESSION_ID "$(jget /tmp/sess.json "['id']")"
else echo "▶️ SESSION_ID exists ($SESSION_ID) — skip"; fi

# --- 5. kickoff (outcome: task + rubric + iteration budget) ---
if [ -z "${KICKED_OFF:-}" ]; then
  echo "Sending 🎯 outcome kickoff (using $KICK_FILE)..."
  python3 -c "
import json
task=open('$KICK_FILE').read(); rubric=open('outcome.md').read()
evt={'type':'user.define_outcome','description':task,'rubric':{'type':'text','content':rubric},'max_iterations':3}
json.dump({'events':[evt]},open('/tmp/kick.json','w'))"
  cp /tmp/kick.json kickoff.json
  code=$(curl -sS -o /tmp/kickresp.json -w '%{http_code}' "$BASE/sessions/$SESSION_ID/events" "${H[@]}" -d @/tmp/kick.json)
  [ "$code" = "200" ] || { echo "kickoff failed ($code):"; cat /tmp/kickresp.json; exit 1; }
  save_id KICKED_OFF "yes"
else echo "🎯 already kicked off — skip"; fi

echo ""
echo "✅ Launch complete. Watch it with:  bash poll.sh"
