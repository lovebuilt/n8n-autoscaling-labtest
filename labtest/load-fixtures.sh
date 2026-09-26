#!/usr/bin/env bash
# labtest/load-fixtures.sh <compose-project>
# Headless fixture load for n8n 2.40 (found by lane 1, 2026-09-26). Runs INSIDE the lab machine.
#   1 copy the two fixture files into the main container
#   2 n8n import:credentials, n8n import:workflow   (a credential with a plain-object "data" is encrypted
#     on import with the instance's key)
#   3 n8n publish:workflow --id=labtestwfecho001    (2.x replaced update:workflow --active=true)
#   4 restart main and webhook so the running processes register the production webhook, then wait
# FIXTURES_DIR overrides where the JSON files are read from (default: this script's fixtures/ folder).
set -euo pipefail
P="${1:?usage: load-fixtures.sh <project>}"
D="${FIXTURES_DIR:-$(cd "$(dirname "$0")" && pwd)/fixtures}"
cid() { docker ps -q --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=$1" | head -1; }
main=$(cid n8n); [ -n "$main" ] || { echo "no n8n main container for project $P" >&2; exit 2; }
docker exec -i "$main" sh -c 'cat > /tmp/labtest-cred-in.json' < "$D/cred-dummy.json"
docker exec -i "$main" sh -c 'cat > /tmp/labtest-wf-in.json' < "$D/wf-echo.json"
docker exec "$main" n8n import:credentials --input=/tmp/labtest-cred-in.json 2>&1 | grep -v -i 'encryption key' | tail -3
docker exec "$main" n8n import:workflow --input=/tmp/labtest-wf-in.json 2>&1 | tail -3
docker exec "$main" n8n publish:workflow --id=labtestwfecho001 2>&1 | tail -3
docker exec "$main" rm -f /tmp/labtest-cred-in.json /tmp/labtest-wf-in.json
for svc in n8n n8n-webhook; do c=$(cid $svc); [ -n "$c" ] && docker restart "$c" >/dev/null && echo "restarted $svc ${c:0:12}"; done
for i in $(seq 1 60); do
  s=$(docker inspect -f '{{.State.Health.Status}}' "$(cid n8n)" 2>/dev/null || echo none)
  w=$(docker inspect -f '{{.State.Health.Status}}' "$(cid n8n-webhook)" 2>/dev/null || echo none)
  [ "$s" = healthy ] && [ "$w" = healthy ] && { echo "main and webhook healthy after restart (${i}x2s)"; exit 0; }
  sleep 2
done
echo "main=$s webhook=$w after 120s" >&2; exit 3
