#!/usr/bin/env bash
# Poll the run's status + outcome verdict. (python, not jq — the embedded system prompt breaks jq.)
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; source IDS.env; set +a
BASE=https://api.anthropic.com/v1
H=(-H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
   -H "anthropic-beta: managed-agents-2026-04-01" -H "content-type: application/json")
curl -sS "$BASE/sessions/$SESSION_ID" "${H[@]}" -o /tmp/sess_poll.json
python3 -c "
import json
d=json.JSONDecoder(strict=False).decode(open('/tmp/sess_poll.json').read())
print('status :', d.get('status'))
for e in d.get('outcome_evaluations',[]):
    print('verdict:', e.get('result'), '—', (e.get('explanation') or '')[:400])
u=d.get('usage') or {}
if u: print('usage  :', u)
"
