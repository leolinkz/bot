#!/usr/bin/env bash
# Regression check: run each eval case as its own session against a PINNED agent version,
# collect the outcome verdicts + usage into results-v<version>.json.
# Usage: bash evals/run-evals.sh   (pins to AGENT_VERSION in IDS.env)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; source IDS.env; set +a
BASE=https://api.anthropic.com/v1
H=(-H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
   -H "anthropic-beta: managed-agents-2026-04-01" -H "content-type: application/json")
VER="${AGENT_VERSION:?set AGENT_VERSION in IDS.env}"
rubric_content=$(cat outcome.md)
out="evals/results-v${VER}.json"; echo "[]" > "$out"

for dir in evals/case-*/; do
  case="$(basename "$dir")"
  inp="$dir/input.txt"; [ -f "$inp" ] || inp="first_prompt.txt"
  echo "→ $case (agent v$VER)"
  python3 -c "
import json
body={'agent':{'type':'agent','id':'$AGENT_ID','version':$VER},'environment_id':'$ENV_ID','title':'eval $case v$VER'}
json.dump(body,open('/tmp/es.json','w'))"
  sid=$(curl -sS "$BASE/sessions" "${H[@]}" -d @/tmp/es.json | python3 -c "import json,sys; print(json.JSONDecoder(strict=False).decode(sys.stdin.read())['id'])")
  python3 -c "
import json
task=open('$inp').read(); rubric=open('outcome.md').read()
evt={'type':'user.define_outcome','description':task,'rubric':{'type':'text','content':rubric},'max_iterations':3}
json.dump({'events':[evt]},open('/tmp/ek.json','w'))"
  curl -sS "$BASE/sessions/$sid/events" "${H[@]}" -d @/tmp/ek.json >/dev/null
  echo "  session $sid started — verdict will land after it finishes; poll with: SESSION_ID=$sid bash poll.sh"
  python3 -c "
import json,os
r=json.load(open('$out')); r.append({'case':'$case','session':'$sid','version':$VER}); json.dump(r,open('$out','w'),indent=2)"
done
echo "Started all eval sessions. Re-poll each session id above for its verdict; promote a new version only if they hold."
