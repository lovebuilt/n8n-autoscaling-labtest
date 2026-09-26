# labtest: what this repository is

`lovebuilt/n8n-autoscaling-labtest` is a **disposable test copy** of `lovebuilt/n8n-autoscaling`, made on
2026-09-26 for the n8n install test run on the Mac lab (MACLAB-1 side run). It is **not the fork**. Nothing
here is deployed anywhere real; keeping or deleting it is Jonah's call.

What was added on `main` (none of the fork's own files were edited):

| File | What |
|---|---|
| `docker-compose.lab.yml` | the one recipe every install variant runs (stock n8n images, queue mode, autoscaler, marker) |
| `docker-compose.fork-lab.yml` | overlay that lets the fork's OWN recipe run on the lab machine (resets its VPS-only mounts, host ports and external networks) |
| `docker-compose.probe.yml` | parser probe for Coolify (a `./` mount, a `${}` volume target, a short-form default, an external network) |
| `labtest/MARKER`, `labtest/marker.Dockerfile` | the running `marker` container shows which branch's files were built |
| `labtest/autoscaler.Dockerfile` | the fork's autoscaler Dockerfile plus one line that bakes in the lab recipe |
| `labtest/fixtures/` | a webhook-to-Code-node workflow and a dummy credential |
| `labtest/check.sh` | readiness, the webhook echo through a worker, the credential decrypts, versions agree |
| `labtest/load-fixtures.sh` | imports and publishes the fixtures headlessly |
| `labtest/redact.sh` | masks secret-looking values before output reaches a receipt |
| `labtest/promote.sh` | check-gated promotion from staging to production |
| `labtest/vars-inventory.txt` | every variable the lab recipe reads, with or without a default |

Branch `staging`: `labtest/MARKER` reads `staging` and `GENERIC_TIMEZONE`'s default differs.
