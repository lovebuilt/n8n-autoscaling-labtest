#!/usr/bin/env bash
# labtest/redact.sh: stdin to stdout, masking the value of any KEY=value, KEY: value or "KEY": "value" pair
# whose key contains PASS, SECRET, KEY, TOKEN or JWT (any case). Everything bound for a receipt goes
# through this first. Repaired by lane 2 (verifier concern 7): quoted values ("..." and '...'), unquoted values
# with spaces (masked to the end of the line), YAML and JSON shapes, Coolify variable objects
# ({"key":"..TOKEN..", ... "value":"..."}) and Authorization Bearer headers. It over-masks on purpose (a key
# like "passed:" is masked too); it never under-masks the shapes in labtest/redact-selftest.sh.
K='[A-Za-z0-9_.-]*(?:PASS|SECRET|KEY|TOKEN|JWT)[A-Za-z0-9_.-]*'
exec perl -pe '
  BEGIN { $K = q{'"$K"'}; }
  # 1 JSON "..KEY..": "value" (the bare field name "key" itself is not a secret)
  s/("(?!key")$K"\s*:\s*")(?:[^"\\]|\\.)*"/$1***"/gi;
  # 2 Coolify variable objects: "key":"..TOKEN..", then its "value" / "real_value"
  s/("key"\s*:\s*"$K"[^{}]*?"(?:real_)?value"\s*:\s*")(?:[^"\\]|\\.)*"/$1***"/gi;
  # 3 Authorization: Bearer <token>
  s/(Bearer\s+)[^\s"\x27]+/$1***/gi;
  # 4 KEY="quoted value" / KEY: "quoted" / KEY='\''quoted'\''
  s/\b($K)(\s*(?:=|:)\s*)"(?:[^"\\]|\\.)*"/$1$2"***"/gi;
  s/\b($K)(\s*(?:=|:)\s*)\x27[^\x27]*\x27/$1$2\x27***\x27/gi;
  # 5 unquoted value, spaces included: masked to the end of the line
  s/\b($K)(=|:[ \t]*)(?!["\x27]|\*\*\*)(\S.*)$/$1$2***/gi;
'
