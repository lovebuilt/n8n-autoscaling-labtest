#!/usr/bin/env bash
# labtest/redact.sh: stdin to stdout, masking the value of any KEY=value, KEY: value or "KEY": "value" pair
# whose key contains PASS, SECRET, KEY, TOKEN or JWT (any case). Everything bound for a receipt goes
# through this first.
exec perl -pe '
  s/("[A-Za-z0-9_.-]*(?:PASS|SECRET|KEY|TOKEN|JWT)[A-Za-z0-9_.-]*"\s*:\s*")[^"]*"/$1***"/gi;
  s/\b([A-Za-z0-9_.-]*(?:PASS|SECRET|KEY|TOKEN|JWT)[A-Za-z0-9_.-]*)(=|:[ \t]*)(?!\*\*\*)([^\s,"'"'"'}\]]+)/$1$2***/gi;
'
