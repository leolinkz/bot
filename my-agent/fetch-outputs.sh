#!/usr/bin/env bash
# List + download the files the run wrote to /mnt/session/outputs/.
set -euo pipefail
cd "$(dirname "$0")"
set -a; source .env; source IDS.env; set +a
BASE=https://api.anthropic.com/v1
H=(-H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" \
   -H "anthropic-beta: managed-agents-2026-04-01" -H "content-type: application/json")
mkdir -p outputs
curl -sS "$BASE/files?scope_id=$SESSION_ID" "${H[@]}" -o /tmp/files.json
python3 -c "
import json,subprocess,os
d=json.JSONDecoder(strict=False).decode(open('/tmp/files.json').read())
hdr=['-H','x-api-key: '+os.environ['ANTHROPIC_API_KEY'],'-H','anthropic-version: 2023-06-01','-H','anthropic-beta: managed-agents-2026-04-01']
for f in d.get('data',[]):
    fn=f.get('filename') or f['id']; print(f['id'], fn)
    subprocess.run(['curl','-sS','$BASE/files/'+f['id']+'/content',*hdr,'-o','outputs/'+fn])
print('downloaded to ./outputs/')
"
