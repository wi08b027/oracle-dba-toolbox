# Oracle DBA Toolbox

Command-line tools for **Oracle DBAs and Linux system administrators** who look after database servers.

> ⚠️ **Run these tools directly on the database server, as the `oracle` OS user** (the Oracle software owner).
> They connect locally with OS authentication (`/ as sysdba`) and read `/proc`. They do **not** work from a client
> machine or over SQL\*Net, and they need no passwords, wallets or TNS entries.

## Tools

| Tool | What it does |
|------|--------------|
| [`cdbtop`](tools/cdbtop/) | Like `top`, for every Oracle instance on the host. Shows which instance, container (CDB$ROOT / PDB) and process uses the most CPU, memory and I/O, with drill-down to a session's current SQL, PL/SQL, plan and waits. |

More tools will follow. Each one lives in its own folder under [`tools/`](tools/).

## Quick start

```bash
# as the oracle user, on the database server
git clone https://github.com/wi08b027/oracle-dba-toolbox.git
cd oracle-dba-toolbox
export PATH="$PWD/bin:$PATH"     # every tool is linked into bin/

cdbtop
```

No clone possible on the server (no git or no internet)? Copy the single script you need. Each tool is one
self-contained file.

## Common requirements

All tools in this repository follow the same rules unless their own README says otherwise:

- **Where:** on the Linux database server itself.
- **As whom:** the Oracle software owner (`oracle`), or another OS user in the OSDBA group (`dba`) of every
  Oracle home on the box. Not as `root`.
- **What they need:** Perl 5.10 or later with core modules only (the Perl in `$ORACLE_HOME/perl` works), plus
  `sqlplus` from each instance's own Oracle home. Nothing to install from CPAN.
- **Oracle versions:** 12c and later (CDB/PDB aware). Some features need 12.2+, as noted per tool.
- **Licensing:** no Diagnostics Pack or Tuning Pack views (no ASH, AWR or SQL Monitor) unless a tool says so
  clearly and makes it optional.
- **Safety:** tools are **read-only**. They query `v$` and `dba_` views and never change the database or the OS.
- **Environment:** tools find instances and Oracle homes themselves (running `pmon` processes, `/etc/oratab`). You
  don't need to set `ORACLE_SID` or `ORACLE_HOME` first.

## Repository layout

```
oracle-dba-toolbox/
├── bin/                  symlinks to every tool, add this folder to PATH
├── tools/
│   └── <tool>/
│       ├── <tool>.pl     the tool itself, one self-contained file
│       ├── README.md     usage, columns, keys, caveats
│       └── test/         smoke tests (mock sqlplus, no database needed)
├── templates/            starting point for a new tool's README
├── CONTRIBUTING.md       conventions for adding a tool
└── LICENSE
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the conventions and the checklist for adding a new tool.

## Disclaimer

These tools are provided as-is under the [MIT License](LICENSE). They are read-only by design, but test them on a
non-production system first. Oracle and the products named here are trademarks of Oracle Corporation. This project
is not affiliated with Oracle.
