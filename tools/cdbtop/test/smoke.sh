#!/usr/bin/env bash
# Smoke test for cdbtop: fake Oracle processes + mock sqlplus, no database needed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../cdbtop.pl"
WORK="$(mktemp -d)"
PIDS=()
cleanup() { kill "${PIDS[@]}" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/home/bin"
cp "$HERE/mock_sqlplus.sh" "$WORK/home/bin/sqlplus"
chmod +x "$WORK/home/bin/sqlplus"
export ORACLE_HOME="$WORK/home"

SID=TESTCDB$$
(exec -a "ora_pmon_$SID" sleep 120) & PIDS+=($!)
(exec -a "oracle$SID (LOCAL=NO)" bash -c 'while :; do :; done') & PIDS+=($!)
sleep 0.5

out="$(perl "$TOOL" -b -d 1 -n 1 -s "$SID")"
echo "$out"

fail=0
check() { grep -q -- "$1" <<<"$out" && echo "OK    $1" || { echo "FAIL  $1"; fail=1; }; }
check "$SID"
check "SALES"
check "READ WRITE"
check "CDB\$ROOT"
exit $fail
