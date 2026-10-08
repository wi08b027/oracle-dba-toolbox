# cdbtop

A monitor like `top` for **all Oracle instances on one Linux host**, aware of CDBs and PDBs.

It answers the question *"which database is eating this box, and what is it running?"* in a few keystrokes:

```
Instances  →  Containers (CDB$ROOT / PDBs)  →  Processes  →  Session detail (SQL, PL/SQL, plan, waits)
```

> ⚠️ Run it **on the database server, as the `oracle` user**. It connects with `/ as sysdba` to every instance it finds.

## Usage

```bash
./cdbtop.pl                          # interactive, refreshes every 5 s
./cdbtop.pl -d 2                     # refresh every 2 s
./cdbtop.pl -s CDB1,CDB2             # only these instances
./cdbtop.pl -b -n 12 -d 300 >> cdbtop.log   # batch: 12 snapshots, 5 min apart (cron, nohup)
```

| Option | Meaning | Default |
|--------|---------|---------|
| `-d, --delay SECS` | refresh interval | 5 |
| `-s, --sid SID[,SID]` | limit to these instances | all running `ora_pmon_*` |
| `-t, --timeout SECS` | max wait for one instance's sqlplus (a hung instance is shown as a timeout, the screen keeps refreshing) | 15 |
| `-c, --connect STR` | sqlplus connect string | `/ as sysdba` |
| `-b, --batch` | print plain-text snapshots to stdout instead of the interactive screen | off |
| `-n, --iterations N` | number of snapshots in batch mode | 1 |

## Screens

**Instances.** One row per running instance: version, CDB yes/no, number of PDBs, open mode, OS processes,
active/total user sessions, OS CPU%, private memory, SGA, PGA, AAS, DB CPU, physical I/O MB/s, logical reads/s and
executions/s.

**Containers.** CDB$ROOT, PDB$SEED, every PDB, and a line for background processes, each with its own CPU%, PGA,
sessions, AAS, DB CPU and size. CPU is assigned to a PDB by mapping each OS process to its session's `CON_ID`.

**Processes.** Every Oracle process of the instance (or of one container): PID, CPU%, memory, PGA, I/O, SID/serial,
PDB, user, SQL_ID, elapsed time of the current call, and what it is doing (wait event or ON CPU, plus module).
Active sessions are green and blocked sessions red, with the blocker shown.

**Session detail.** For the selected process:
- session info (user, client, module/action, state, blocker)
- **SQL text** that is running now, or the last one if the session is idle
- **PL/SQL entry point and the subprogram executing now** (`owner.package.procedure`)
- **execution plan** (`dbms_xplan.display_cursor`)
- top non-idle waits and key session statistics since logon

The query runs inside the session's own PDB, so object names resolve correctly.

## Keys

| Key | Action |
|-----|--------|
| ↑ ↓ `j` `k`, PgUp/PgDn, Home/End | move |
| Enter, → | drill down |
| Esc, ←, Backspace, `b` | back |
| `p` | process list (of the selected instance, all containers, or of the selected container) |
| `s` | session detail of the selected process |
| `c` `m` `a` `o` `e` `n` | sort by CPU / memory / active sessions or AAS / I/O / elapsed / name |
| `i` | processes: show only busy (≥ 0.5 % CPU) or ACTIVE ones |
| `w` | session detail: toggle line wrap |
| `+` `-` | change refresh interval |
| `r`, Space | refresh now |
| `?`, `h` | help |
| `q` | quit |

## Columns

| Column | Source |
|--------|--------|
| %CPU | OS CPU from `/proc/<pid>/stat` since the last refresh, as in `top` (100 = one full core) |
| PRIV_MB | private resident memory of the processes (RSS minus shared, so SGA is not counted) |
| SGA_MB / PGA_MB | `v$sga`, `v$pgastat` "total PGA allocated"; per process `v$process.pga_alloc_mem` |
| AAS | average active sessions = Δ DB time / elapsed (`v$sys_time_model`, per PDB `v$con_sys_time_model`) |
| DBCPU | CPU used by DB calls, in cores = Δ DB CPU / elapsed |
| IO_MB/s | Δ `physical read total bytes` + `physical write total bytes` (`v$sysstat`) |
| LIO/s, EXEC/s | Δ `session logical reads`, `execute count` |
| STATUS | RW, RO, ROAP (read only with apply), MNT, NOMNT; `/S` = standby |

Rate columns show `-` until the second sample, about 1 second after start.

## Requirements

- Linux, Perl 5.10+ with core modules only (`$ORACLE_HOME/perl/bin/perl` works)
- run as the Oracle software owner, or a member of the OSDBA group of **every** Oracle home on the host
- Oracle 12.1+. Per-PDB AAS and DB CPU need 12.2+ (`v$con_sys_time_model`).
- Oracle homes are found automatically from the running `pmon` process, with `/etc/oratab` as a fallback, so
  instances in different homes and versions work side by side.
- **No Diagnostics or Tuning Pack** usage. Only `v$session`, `v$process`, `v$sql`, `v$sysstat`, time model and
  `dba_objects` / `dba_procedures` are queried.

## How it works

On each refresh cdbtop reads `/proc` for all `ora_*` and `oracle<SID>` processes. It then starts one
`sqlplus -s "/ as sysdba"` per instance **in parallel**, each with that instance's own `ORACLE_HOME`. The SQL output
is joined back to the OS processes via `v$process.spid`. A hung instance only shows as a timeout and does not block
the others. Its own monitoring session is marked `(cdbtop)` and left out of the session counts.

Overhead: one short sqlplus connection per instance per interval. Use `-d 10` or more on very busy hosts.

## Known limitations

- `threaded_execution=true`: several sessions share one OS process, so per-process CPU can't be split between them.
- Shared servers / DRCP: a session moves between server processes, so the process-to-session mapping is a snapshot.
- ASM and APX instances are not shown separately (their processes are named differently).
- `ORACLE_PDB_SID` and `TWO_TASK` are cleared on purpose, so the connection always goes to CDB$ROOT.

## Tests

`test/smoke.sh` starts fake `ora_pmon_*` processes and a mock `sqlplus`, then runs cdbtop in batch mode. No database
is needed:

```bash
./test/smoke.sh
```
