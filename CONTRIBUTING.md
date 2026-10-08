# Contributing a tool

The toolbox is for DBAs and sysadmins working **on the database server as `oracle`**. Every tool should be easy to
copy to a locked-down server and run right away.

## Conventions

1. **One folder per tool:** `tools/<name>/` with `<name>.pl` (or `.sh` / `.sql`), a `README.md` and `test/`.
2. **One self-contained file.** No CPAN modules, no shared libraries between tools. Someone must be able to `scp`
   a single file to a server and run it.
3. **Core Perl 5.10+ or POSIX bash.** Assume only what ships with Oracle Linux / RHEL and the Oracle home.
4. **Read-only.** Never change the database, the OS or Oracle files. If a tool ever needs to write, it must ask
   explicitly and document it in bold in its README.
5. **Local OS authentication.** Connect with `/ as sysdba` (overridable with `-c`). Discover instances from
   `ora_pmon_*` and homes from the running process or `/etc/oratab`. Don't require `ORACLE_SID` to be set.
6. **CDB/PDB aware.** Show the container for everything that belongs to one.
7. **No extra-cost options by default.** Using ASH/AWR (Diagnostics Pack) or SQL Monitor (Tuning Pack) must be
   opt-in behind a flag, and the README must say so.
8. **Robust against a sick instance.** Put a timeout on every sqlplus call, and don't let one hung instance block
   the others.
9. **Common options:** `-h` help, `-s SID[,SID]` instance filter, `-c` connect string, `-t` timeout, and `-b` batch
   (plain text) output where it makes sense.
10. **Link it in `bin/`:** `ln -s ../tools/<name>/<name>.pl bin/<name>`, and add a row to the table in the root
    `README.md`.

## Checklist for a new tool

- [ ] `tools/<name>/` created from [`templates/TOOL_README.md`](templates/TOOL_README.md)
- [ ] script is executable and passes `perl -c` / `bash -n`
- [ ] `test/smoke.sh` runs without a database (mock `sqlplus`)
- [ ] symlink in `bin/`
- [ ] row added to the tool table in the root README
- [ ] tested on a real host as `oracle` (note the versions in the PR)
