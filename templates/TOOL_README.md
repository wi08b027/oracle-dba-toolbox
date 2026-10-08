# <tool name>

One sentence: what question does this tool answer for a DBA or admin?

> ⚠️ Run it **on the database server, as the `oracle` user**.

## Usage

```bash
./<tool>.pl [options]
```

| Option | Meaning | Default |
|--------|---------|---------|
| `-h` | help | |
| `-s SID[,SID]` | limit to these instances | all running |
| `-c STR` | sqlplus connect string | `/ as sysdba` |
| `-t SECS` | sqlplus timeout per instance | 15 |
| `-b` | plain-text batch output | off |

## Output

Describe each column and where it comes from (view / statistic / `/proc` file).

## Requirements

- Oracle versions supported, plus any features that need a newer version
- licensing: which views are used, and whether any extra-cost pack is involved (opt-in only)

## Known limitations

## Tests

```bash
./test/smoke.sh
```
