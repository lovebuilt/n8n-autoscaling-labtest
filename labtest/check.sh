#!/usr/bin/env bash
# labtest/check.sh <compose-project> <base-url> [expected-version]
# The "it really works" check for one n8n install (TEST-PLAN.md "Fixtures"). Runs INSIDE the lab machine
# (it uses docker exec). Exit 0 only if all four steps pass. Never prints the credential or any secret.
#   1  <base-url>/healthz/readiness answers 200
#   2  POST {"a":2,"b":3} to <base-url>/webhook/labtest-echo returns 200 and {"sum":5}; the same POST made
#      from inside the n8n-webhook container (the webhook process) must also return {"sum":5}.
#      The Code node only runs on a worker's task runner, so a pass proves webhook, queue, worker, runner.
#   3  the dummy credential exports decrypted to a file INSIDE the main container; only the sha256 of its
#      value is printed and compared with the known value (proves the encryption key survived)
#   4  n8n --version in main, webhook and every worker container: all equal (and equal to [expected-version])
set -u
P="${1:?usage: check.sh <project> <base-url> [expected-version]}"
URL="${2:?usage: check.sh <project> <base-url> [expected-version]}"; URL="${URL%/}"
EXP="${3:-}"
KNOWN_SHA=ef40cef51f079098b52ae8cbda4a89e99c9e88cc19b7026653a76c7045ab0dc6  # sha256("labtest-dummy-not-a-secret")
CRED_ID=labtestcred00001
cids() { docker ps -q --filter "label=com.docker.compose.project=$P" --filter "label=com.docker.compose.service=$1"; }
fail=0
echo "check: project=$P base=$URL expected=${EXP:-any} at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 1 readiness
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$URL/healthz/readiness")
if [ "$code" = 200 ]; then echo "STEP1 PASS readiness http=$code"; else echo "STEP1 FAIL readiness http=$code"; fail=1; fi

# 2 webhook through the queue to a worker's Code node
tmp=$(mktemp); code=$(curl -s -o "$tmp" -w '%{http_code}' -m 60 -X POST -H 'Content-Type: application/json' \
  -d '{"a":2,"b":3}' "$URL/webhook/labtest-echo"); body=$(head -c 300 "$tmp"); rm -f "$tmp"
s2a=FAIL; [ "$code" = 200 ] && echo "$body" | jq -e '.sum == 5' >/dev/null 2>&1 && s2a=PASS
wh=$(cids n8n-webhook | head -1); s2b=FAIL; whout="no n8n-webhook container"
if [ -n "$wh" ]; then
  whout=$(docker exec "$wh" node -e "fetch('http://localhost:5678/webhook/labtest-echo',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({a:2,b:3})}).then(async r=>{console.log(r.status+' '+(await r.text()).slice(0,300))}).catch(e=>{console.log('ERR '+e.message)})" 2>&1 | tail -1)
  case "$whout" in "200 "*) echo "${whout#200 }" | jq -e '.sum == 5' >/dev/null 2>&1 && s2b=PASS ;; esac
fi
if [ $s2a = PASS ] && [ $s2b = PASS ]; then r=PASS; else r=FAIL; fail=1; fi
echo "STEP2 $r webhook via main: http=$code body=$body ($s2a) | via webhook process: $whout ($s2b)"

# 3 credential decrypts (value never printed)
main=$(cids n8n | head -1); got=none
if [ -n "$main" ]; then
  got=$(docker exec "$main" sh -c "n8n export:credentials --id=$CRED_ID --decrypted --output=/tmp/labtest-cred.json >/dev/null 2>&1; node -e \"const c=require('/tmp/labtest-cred.json');const x=Array.isArray(c)?c[0]:c;process.stdout.write(require('crypto').createHash('sha256').update(String(x.data.value)).digest('hex'))\" 2>/dev/null; rm -f /tmp/labtest-cred.json" 2>/dev/null)
fi
if [ "$got" = "$KNOWN_SHA" ]; then echo "STEP3 PASS credential decrypts sha256=${got:0:12}"; else echo "STEP3 FAIL credential sha256=${got:0:12} want=${KNOWN_SHA:0:12}"; fail=1; fi

# 4 versions everywhere
vers=""; allv=""
for svc in n8n n8n-webhook n8n-worker; do
  for c in $(cids $svc); do
    v=$(docker exec "$c" n8n --version 2>/dev/null | tail -1 | tr -d '\r')
    vers="$vers $svc:${c:0:12}=$v"; allv="$allv $v"
  done
done
uniq=$(echo $allv | tr ' ' '\n' | grep -v '^$' | sort -u)
n=$(echo "$uniq" | grep -c .)
r=PASS
if [ "$n" != 1 ]; then r=FAIL; fi
if [ -n "$EXP" ] && [ "$uniq" != "$EXP" ]; then r=FAIL; fi
[ $r = FAIL ] && fail=1
echo "STEP4 $r versions:$vers"

echo "CHECK_RC=$fail"
exit $fail
