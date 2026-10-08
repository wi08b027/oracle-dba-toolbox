#!/usr/bin/env bash
# Mock sqlplus for cdbtop tests: prints the tagged lines cdbtop expects, with counters growing over time.
f="${@: -1}"; f="${f#@}"
if grep -q 'v\$con_sys_time_model' "$f"; then
  n=$(date +%s%N); n=${n:0:13}
  echo "I|$ORACLE_SID|19.0.0.0.0|OPEN|20260101080000"
  echo "V|19.24.0.0.0"
  echo "B|YES|READ WRITE|PRIMARY"
  echo "G|8192"; echo "P|1500"
  echo "Y|DB time|$((n*1500))"; echo "Y|DB CPU|$((n*800))"
  echo "Z|session logical reads|$((n*50))"
  echo "Z|physical read total bytes|$((n*2000))"
  echo "Z|physical write total bytes|$((n*500))"
  echo "Z|execute count|$((n*3))"
  echo "D|1|CDB\$ROOT|READ WRITE|4000"
  echo "D|2|PDB\$SEED|READ ONLY|900"
  echo "D|3|SALES|READ WRITE|51200"
  echo "T|3|DB time|$((n*1200))"; echo "T|3|DB CPU|$((n*600))"
  echo "T|1|DB time|$((n*300))";  echo "T|1|DB CPU|$((n*100))"
  pm=$(pgrep -f "^ora_pmon_$ORACLE_SID" | head -1)
  fg=$(pgrep -f "^oracle$ORACLE_SID " | head -1)
  echo "S|$pm|2|1|0|-|ACTIVE|-|pmon timer|PMON|BACKGROUND|20.1|99|Idle|-|WAITING|N"
  echo "S|$fg|123|4567|3|APPUSER|ACTIVE|a1b2c3d4e5f6g|db file sequential read|ORDERS_BATCH|USER|55.3|42|User I/O|-|WAITING|N"
else
  echo "===== SESSION"
  echo "SID,SERIAL#  : 123,4567"
  echo "===== SQL TEXT  (CURRENTLY EXECUTING, sql_id a1b2c3d4e5f6g)"
  echo "SELECT * FROM orders WHERE id = :1"
fi
