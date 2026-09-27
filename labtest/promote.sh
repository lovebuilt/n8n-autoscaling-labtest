#!/usr/bin/env bash
# labtest/promote.sh <staging-app-uuid> <prod-app-uuid> <staging-base-url> <prod-base-url> <expected-version>
# The check-gated promotion (TEST-PLAN.md T4b, T4c). Runs on the MAC, from the labtest working clone
# (the only place with GitHub credentials). Written by lane 1; repaired by lane 2 (verifier concern 6) and by lane 3
# (verifier 2 concerns 4 and 5): an expected version is required, and the promoted commit is bound to what the checked
# staging containers run by the deployment commit AND the image ids, never by marker text alone.
#   1 staging's NEWEST deployment (Coolify, newest first by created_at) must be "finished"; a newer failed,
#     queued or in-progress deployment refuses (the running stack may not be what that record says)
#   2 staging's running identity is recorded: container id and image id of every service. The marker file in its
#     marker container must equal labtest/MARKER at the deployment's commit (a consistency check only)
#   3 run check.sh against staging with the expected version; a non-zero exit refuses
#   4 re-read staging's newest deployment (same uuid, still finished) and its running identity (unchanged):
#     nothing was redeployed or recreated while checking
#   5 fast-forward PROD_BRANCH to EXACTLY that commit (refuses anything that is not a fast-forward), push
#   6 call the prod app's Deploy Webhook, poll to a final status (15 min cap); production's NEWEST deployment must be
#     that one, finished, on the promoted commit; the stock-image services (n8n, n8n-webhook, n8n-worker,
#     n8n-worker-runner, redis, postgres) must run the same image ids as staging; then check.sh on production with
#     the expected version. Built services (marker, n8n-autoscaler) are built per app, so their image ids differ by
#     design; their marker text is compared instead and printed.
# Every refusal before step 5 writes nothing anywhere. Exit codes: 10 token, 20 staging check, 21 staging deployment,
# 22 fetch or marker, 23 not a fast-forward, 24 origin, 25 push, 26 no prod deployment, 27 prod deployment not
# finished, 28 staging moved during the check, 29 prod deployment commit or newest mismatch, 30 image ids differ,
# 31 prod check failed.
# Env: COOLIFY_URL (default http://localhost:8000), STAGING_BRANCH (env-staging), PROD_BRANCH (env-prod),
#      DRY_RUN=1 (stop after step 4 and print what would be pushed; used for red-first tests).
# The token is read with get-secret COOLIFY_API_TOKEN_LAB inside this process and never printed.
set -uo pipefail
A="${1:?staging app uuid}"; B="${2:?prod app uuid}"; AURL="${3:?staging base url}"; BURL="${4:?prod base url}"
EXP="${5:?expected n8n version}"
CU="${COOLIFY_URL:-http://localhost:8000}"; SB="${STAGING_BRANCH:-env-staging}"; PB="${PROD_BRANCH:-env-prod}"
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(get-secret COOLIFY_API_TOKEN_LAB 2>/dev/null)"; [ -n "${COOLIFY_API_TOKEN_LAB:-}" ] || { echo "promote: no COOLIFY_API_TOKEN_LAB" >&2; exit 10; }
api() { curl -s -m 30 -H "Authorization: Bearer $COOLIFY_API_TOKEN_LAB" -H 'Accept: application/json' "$@"; }
newest() { api "$CU/api/v1/deployments/applications/$1?skip=0&take=20" | jq -c 'if type=="object" and (.deployments|type)=="array" then .deployments else [] end | sort_by(.created_at) | reverse | .[0] // {} | {deployment_uuid, status, commit}'; }
ts() { date +%s; }
chk() { orb -m lab sudo bash -s -- "$@" < "$HERE/check.sh"; }
marker() { orb -m lab sudo bash -c "c=\$(docker ps -q --filter label=com.docker.compose.project=$1 --filter label=com.docker.compose.service=marker | head -1); [ -n \"\$c\" ] && docker exec \$c cat /labtest/MARKER"; }
# "service container-id image-id" per running container of a compose project, sorted
ident() { orb -m lab sudo bash -c "for c in \$(docker ps -q --filter label=com.docker.compose.project=$1); do docker inspect -f '{{index .Config.Labels \"com.docker.compose.service\"}} {{.Id}} {{.Image}}' \$c; done" | awk '{print $1, substr($2,1,12), substr($3,8,12)}' | sort; }
STOCK='^(n8n|n8n-webhook|n8n-worker|n8n-worker-runner|redis|postgres) '
imgs() { grep -E "$STOCK" | awk '{print $1, $3}' | sort -u; }

t0=$(ts)
n1=$(newest "$A"); echo "promote: staging newest deployment $n1"
st=$(echo "$n1" | jq -r '.status // empty'); sha=$(echo "$n1" | jq -r '.commit // empty'); d1=$(echo "$n1" | jq -r '.deployment_uuid // empty')
[ "$st" = finished ] || { echo "promote: REFUSED, staging's newest deployment is '${st:-none}', not finished; production untouched"; exit 21; }
case "$sha" in ""|HEAD|null) echo "promote: REFUSED, no commit on staging's newest deployment"; exit 21 ;; esac

i1=$(ident "$A"); echo "promote: staging identity before the check (service container image):"; echo "$i1" | sed 's/^/  /'
[ -n "$i1" ] || { echo "promote: REFUSED, staging has no running containers; production untouched"; exit 21; }
git fetch -q origin "$SB" "$PB" || { echo "promote: REFUSED, git fetch failed"; exit 22; }
want=$(git show "$sha:labtest/MARKER" 2>/dev/null); got=$(marker "$A")
echo "promote: marker at $sha: '$want' | running on staging: '$got'"
[ -n "$want" ] && [ "$want" = "$got" ] || { echo "promote: REFUSED, the running staging marker does not match commit $sha; production untouched"; exit 22; }

echo "promote: check staging ($A) expecting $EXP"
chk "$A" "$AURL" "$EXP"; rc=$?; t1=$(ts); echo "promote: staging check rc=$rc seconds=$((t1-t0))"
[ $rc -eq 0 ] || { echo "promote: REFUSED, staging check failed; production untouched"; exit 20; }

n2=$(newest "$A"); d2=$(echo "$n2" | jq -r '.deployment_uuid // empty'); st2=$(echo "$n2" | jq -r '.status // empty')
i2=$(ident "$A")
[ "$d2" = "$d1" ] && [ "$st2" = finished ] || { echo "promote: REFUSED, staging deployments moved during the check ($n2); production untouched"; exit 28; }
[ "$i2" = "$i1" ] || { echo "promote: REFUSED, staging containers changed during the check; production untouched"; exit 28; }
echo "promote: staging runs commit $sha (deployment $d1), checked, identity unchanged"

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
nb=$(newest "$B"); echo "promote: prod newest deployment $nb"
[ "$(echo "$nb" | jq -r .deployment_uuid)" = "$dep" ] && [ "$(echo "$nb" | jq -r .commit)" = "$sha" ] || { echo "promote: prod's newest deployment is not $dep on $sha" >&2; exit 29; }
# wait (5 min cap) for production's containers to settle, then compare stock image ids with staging's
for i in $(seq 1 60); do orb -m lab sudo docker ps -a --filter label=com.docker.compose.project=$B --format '{{.Status}}' | grep -qiE 'starting|restarting|created' || break; sleep 5; done
ib=$(ident "$B"); echo "promote: prod identity after the deploy (service container image):"; echo "$ib" | sed 's/^/  /'
ia_imgs=$(echo "$i1" | imgs); ib_imgs=$(echo "$ib" | imgs)
echo "promote: stock image ids staging | prod:"; paste -d'|' <(echo "$ia_imgs") <(echo "$ib_imgs") | sed 's/^/  /'
[ -n "$ia_imgs" ] && [ "$ia_imgs" = "$ib_imgs" ] || { echo "promote: stock image ids differ between staging and prod" >&2; exit 30; }
echo "promote: marker staging '$got' | prod '$(marker "$B")'"
chk "$B" "$BURL" "$EXP"; rc=$?; t5=$(ts); echo "promote: prod check rc=$rc seconds=$((t5-t4)) total=$((t5-t0))"
[ $rc -eq 0 ] || exit 31
exit 0
