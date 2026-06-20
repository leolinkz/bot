#!/usr/bin/env bash
# Create the scheduled deployment — run this ONLY after a session has passed the rubric.
# initial_events are replayed verbatim every run, so the task text uses relative dates only.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; source IDS.env; set +a
BASE=https://api.anthropic.com/v1
H=(-H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
   -H "anthropic-beta: managed-agents-2026-04-01" -H "content-type: application/json")

if [ -n "${DEPLOYMENT_ID:-}" ]; then echo "🗓️ DEPLOYMENT_ID exists ($DEPLOYMENT_ID) — skip"; exit 0; fi

python3 -c "
import json
task=open('first_prompt.txt').read(); rubric=open('outcome.md').read()
evt={'type':'user.define_outcome','description':task,'rubric':{'type':'text','content':rubric},'max_iterations':3}
body={'name':'fx-trade-scout — hourly R_75 (V75) scan','agent':'$AGENT_ID','environment_id':'$ENV_ID',
 'initial_events':[evt],
 'resources':[{'type':'memory_store','memory_store_id':'$MEMSTORE_ID','access':'read_write',
   'instructions':'Your trade log. Read it first each run to reconcile open ideas and update the track record; append every new idea.'}],
 'schedule':{'type':'cron','expression':'0 * * * *','timezone':'UTC'}}
json.dump(body,open('/tmp/dep.json','w'))"
cp /tmp/dep.json deployment.json

code=$(curl -sS -o /tmp/depresp.json -w '%{http_code}' "$BASE/deployments?beta=true" "${H[@]}" -d @/tmp/dep.json)
[ "$code" = "200" ] || { echo "deployment create failed ($code):"; cat /tmp/depresp.json; exit 1; }
DEP=$(python3 -c "import json; d=json.JSONDecoder(strict=False).decode(open('/tmp/depresp.json').read()); print(d['id'])")
echo "DEPLOYMENT_ID=$DEP" >> IDS.env
echo "✅ 🗓️ deployment $DEP"
python3 -c "import json; d=json.JSONDecoder(strict=False).decode(open('/tmp/depresp.json').read()); print('upcoming runs:', (d.get('schedule') or {}).get('upcoming_runs_at'))"

echo "Firing a manual test run so you see it fire before trusting the cron..."
curl -sS -X POST -d '{}' "$BASE/deployments/$DEP/run?beta=true" "${H[@]}" -o /tmp/deprun.json -w 'manual run: HTTP %{http_code}\n'
