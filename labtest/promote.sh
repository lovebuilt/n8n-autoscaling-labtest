#!/usr/bin/env bash
# labtest/promote.sh <staging-app-uuid> <prod-app-uuid> <staging-base-url> <prod-base-url>
# The check-gated promotion (TEST-PLAN.md T4b, T4c). Runs on the MAC, from the labtest working clone
# (the only place with GitHub credentials). Written by lane 1; repaired by lane 2 (verifier concern 6) so the
# promoted commit is bound to what the checked staging containers actually run:
#   1 staging's NEWEST deployment (Coolify, newest first by created_at) must be "finished"; a newer failed,
#     queued or in-progress deployment refuses (the running stack may not be what that record says)
#   2 the marker file in staging's running marker container must equal labtest/MARKER at that commit
#   3 run check.sh against staging; a non-zero exit refuses
#   4 re-read staging's newest deployment: the same uuid, still finished (nothing moved while checking)
#   5 fast-forward PROD_BRANCH to EXACTLY that commit (refuses anything that is not a fast-forward), push
#   6 call the prod app's Deploy Webhook, poll to a final status (15 min cap), require prod's newest deployment
#     commit to equal the promoted commit, then run check.sh against production
# Every refusal happens before step 5, so a refused promotion writes nothing anywhere.
# Env: COOLIFY_URL (default http://localhost:8000), STAGING_BRANCH (env-staging), PROD_BRANCH (env-prod),
#      DRY_RUN=1 (stop after step 4 and print what would be pushed; used for red-first tests).
# The token is read with get-secret COOLIFY_API_TOKEN_LAB inside this process and never printed.
set -uo pipefail
A="${1:?staging app uuid}"; B="${2:?prod app uuid}"; AURL="${3:?staging base url}"; BURL="${4:?prod base url}"
CU="${COOLIFY_URL:-http://localhost:8000}"; SB="${STAGING_BRANCH:-env-staging}"; PB="${PROD_BRANCH:-env-prod}"
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(get-secret COOLIFY_API_TOKEN_LAB 2>/dev/null)"; [ -n "${COOLIFY_API_TOKEN_LAB:-}" ] || { echo "promote: no COOLIFY_API_TOKEN_LAB" >&2; exit 10; }
api() { curl -s -m 30 -H "Authorization: Bearer $COOLIFY_API_TOKEN_LAB" -H 'Accept: application/json' "$@"; }
newest() { api "$CU/api/v1/deployments/applications/$1?skip=0&take=20" | jq -c 'if type=="object" and (.deployments|type)=="array" then .deployments else [] end | sort_by(.created_at) | reverse | .[0] // {} | {deployment_uuid, status, commit}'; }
ts() { date +%s; }
chk() { orb -m lab sudo bash -s -- "$@" < "$HERE/check.sh"; }
marker() { orb -m lab sudo bash -c "c=\$(docker ps -q --filter label=com.docker.compose.project=$1 --filter label=com.docker.compose.service=marker | head -1); [ -n \"\$c\" ] && docker exec \$c cat /labtest/MARKER"; }

t0=$(ts)
n1=$(newest "$A"); echo "promote: staging newest deployment $n1"
st=$(echo "$n1" | jq -r '.status // empty'); sha=$(echo "$n1" | jq -r '.commit // empty'); d1=$(echo "$n1" | jq -r '.deployment_uuid // empty')
[ "$st" = finished ] || { echo "promote: REFUSED, staging's newest deployment is '${st:-none}', not finished; production untouched"; exit 21; }
case "$sha" in ""|HEAD|null) echo "promote: REFUSED, no commit on staging's newest deployment"; exit 21 ;; esac

git fetch -q origin "$SB" "$PB" || { echo "promote: REFUSED, git fetch failed"; exit 22; }
want=$(git show "$sha:labtest/MARKER" 2>/dev/null); got=$(marker "$A")
echo "promote: marker at $sha: '$want' | running on staging: '$got'"
[ -n "$want" ] && [ "$want" = "$got" ] || { echo "promote: REFUSED, the running staging marker does not match commit $sha; production untouched"; exit 22; }

echo "promote: check staging ($A)"
chk "$A" "$AURL"; rc=$?; t1=$(ts); echo "promote: staging check rc=$rc seconds=$((t1-t0))"
[ $rc -eq 0 ] || { echo "promote: REFUSED, staging check failed; production untouched"; exit 20; }

n2=$(newest "$A"); d2=$(echo "$n2" | jq -r '.deployment_uuid // empty'); st2=$(echo "$n2" | jq -r '.status // empty')
[ "$d2" = "$d1" ] && [ "$st2" = finished ] || { echo "promote: REFUSED, staging deployments moved during the check ($n2); production untouched"; exit 28; }
echo "promote: staging runs commit $sha (deployment $d1), checked"

git merge-base --is-ancestor "origin/$PB" "$sha" || { echo "promote: REFUSED, $sha is not a fast-forward of $PB"; exit 23; }
echo "promote: origin url $(git remote get-url origin)"
case "$(git remote get-url origin)" in *n8n-autoscaling-labtest.git) ;; *) echo "promote: origin is not the labtest repo" >&2; exit 24 ;; esac
if [ "${DRY_RUN:-0}" = 1 ]; then echo "promote: DRY_RUN, would push $sha to $PB and deploy $B"; exit 0; fi
t2=$(ts); git push origin "$sha:refs/heads/$PB" || exit 25; t3=$(ts); echo "promote: pushed $PB=$sha seconds=$((t3-t2))"

dep=$(api -X POST "$CU/api/v1/deploy?uuid=$B&force=false" | jq -r '.deployments[0].deployment_uuid // empty')
[ -n "$dep" ] || { echo "promote: no deployment uuid from the deploy webhook" >&2; exit 26; }
echo "promote: prod deployment $dep"
st=""; for i in $(seq 1 180); do
  st=$(api "$CU/api/v1/deployments/$dep" | jq -r '.status // empty')
  case "$st" in finished|failed|cancelled*) break ;; esac; sleep 5
done; t4=$(ts); echo "promote: prod deployment status=$st seconds=$((t4-t3))"
[ "$st" = finished ] || exit 27
pc=$(api "$CU/api/v1/deployments/$dep" | jq -r '.commit // empty'); echo "promote: prod deployment commit $pc"
[ "$pc" = "$sha" ] || { echo "promote: prod deployed $pc, not the promoted $sha" >&2; exit 29; }
chk "$B" "$BURL"; rc=$?; t5=$(ts); echo "promote: prod check rc=$rc seconds=$((t5-t4)) total=$((t5-t0))"
exit $rc
