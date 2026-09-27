#!/usr/bin/env bash
# labtest/redact-selftest.sh [redact-script]: feeds FAKE secrets in every shape redact.sh must handle and fails
# (exit 1) if any fake value survives or if a harmless line was damaged. All values here are fake.
R="${1:-$(cd "$(dirname "$0")" && pwd)/redact.sh}"
in=$(cat <<'X'
N8N_ENCRYPTION_KEY=fakeunquoted1
POSTGRES_PASSWORD: fakeyaml2
  "redisPassword": "fakejson3",
"N8N_RUNNERS_AUTH_TOKEN=fakeinarray4",
API_TOKEN="fake quoted five"
DB_SECRET='fake single six'
JWT_SECRET=fake spaced seven
  N8N_RUNNERS_AUTH_TOKEN: "fakeyamlquoted8"
{"key":"N8N_ENCRYPTION_KEY","value":"fakecoolify9","is_preview":false}
Authorization: Bearer fakebearer10
{"webhook_secret": "fake escaped \" eleven"}
STEP1 PASS readiness http=200
harmless=value
{"key":"N8N_VERSION","value":"2.39.8"}
X
)
out=$(printf '%s\n' "$in" | "$R")
printf '%s\n' "$out"
bad=0
for w in fakeunquoted1 fakeyaml2 fakejson3 fakeinarray4 five six seven fakeyamlquoted8 fakecoolify9 fakebearer10 eleven; do
  case "$out" in *"$w"*) echo "LEAK: $w"; bad=1 ;; esac
done
for keep in 'STEP1 PASS readiness http=200' 'harmless=value' '"value":"2.39.8"'; do
  case "$out" in *"$keep"*) ;; *) echo "DAMAGED: $keep"; bad=1 ;; esac
done
echo "SELFTEST_RC=$bad"; exit $bad
