#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTANCE_ID="$(jq -r '.[0].instance_id' "$ROOT_DIR/swe_bench_pro_js_ts_basic_10.json")"

echo "running first instance only: $INSTANCE_ID"
"$ROOT_DIR/run_codex_bugfixes.sh" "$INSTANCE_ID"
