#!/usr/bin/env bash
# labtest/promote.sh <staging-app-uuid> <prod-app-uuid> <staging-base-url> <prod-base-url>
# The check-gated promotion (TEST-PLAN.md T4b, T4c). Runs on the MAC, from the labtest working clone
# (the only place with GitHub credentials). Written by lane 1; first exercised by lane 3.
#   1 run check.sh against staging (inside the lab machine); a non-zero exit stops here, nothing touched
#   2 read the commit staging runs from Coolify's latest finished deployment of the staging app
#   3 fast-forward env-prod to EXACTLY that commit (refuses anything that is not a fast-forward), push
#   4 call the prod app's Deploy Webhook, poll its deployment to a final status (15 min cap)
#   5 run check.sh against production
# Env: COOLIFY_URL (default http://localhost:8000), STAGING_BRANCH (env-staging), PROD_BRANCH (env-prod).
# The token is read with get-secret COOLIFY_LAB_TOKEN inside this process and never printed.
set -uo pipefail
A="${1:?staging app uuid}"; B="${2:?prod app uuid}"; AURL="${3:?staging base url}"; BURL="${4:?prod base url}"
CU="${COOLIFY_URL:-http://localhost:8000}"; SB="${STAGING_BRANCH:-env-staging}"; PB="${PROD_BRANCH:-env-prod}"
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(get-secret COOLIFY_LAB_TOKEN 2>/dev/null)"; [ -n "${COOLIFY_LAB_TOKEN:-}" ] || { echo "promote: no COOLIFY_LAB_TOKEN" >&2; exit 10; }
api() { curl -s -m 30 -H "Authorization: Bearer $COOLIFY_LAB_TOKEN" -H 'Accept: application/json' "$@"; }
ts() { date +%s; }
chk() { orb -m lab sudo bash -s -- "$@" < "$HERE/check.sh"; }

t0=$(ts); echo "promote: check staging ($A)"
chk "$A" "$AURL"; rc=$?; t1=$(ts); echo "promote: staging check rc=$rc seconds=$((t1-t0))"
[ $rc -eq 0 ] || { echo "promote: REFUSED, staging check failed; production untouched"; exit 20; }

sha=$(api "$CU/api/v1/deployments/applications/$A?skip=0&take=10" | jq -r '[(.deployments // .)[] | select(.status=="finished")][0].commit // empty')
[ -n "$sha" ] && [ "$sha" != HEAD ] || { echo "promote: could not read the commit staging runs" >&2; exit 21; }
echo "promote: staging runs commit $sha"

git fetch -q origin "$SB" "$PB" || exit 22
git merge-base --is-ancestor "origin/$PB" "$sha" || { echo "promote: $sha is not a fast-forward of $PB; refused" >&2; exit 23; }
echo "promote: origin url $(git remote get-url origin)"
case "$(git remote get-url origin)" in *n8n-autoscaling-labtest.git) ;; *) echo "promote: origin is not the labtest repo" >&2; exit 24 ;; esac
t2=$(ts); git push origin "$sha:refs/heads/$PB" || exit 25; t3=$(ts); echo "promote: pushed $PB=$sha seconds=$((t3-t2))"

dep=$(api "$CU/api/v1/deploy?uuid=$B&force=false" | jq -r '.deployments[0].deployment_uuid // empty')
[ -n "$dep" ] || { echo "promote: no deployment uuid from the deploy webhook" >&2; exit 26; }
echo "promote: prod deployment $dep"
st=""; for i in $(seq 1 180); do
  st=$(api "$CU/api/v1/deployments/$dep" | jq -r '.status // empty')
  case "$st" in finished|failed|cancelled*) break ;; esac; sleep 5
done; t4=$(ts); echo "promote: prod deployment status=$st seconds=$((t4-t3))"
[ "$st" = finished ] || exit 27
chk "$B" "$BURL"; rc=$?; t5=$(ts); echo "promote: prod check rc=$rc seconds=$((t5-t4)) total=$((t5-t0))"
exit $rc
