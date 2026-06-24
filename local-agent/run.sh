#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[ -f config.env ] && { set -a; source config.env; set +a; }
exec python3 agent.py
