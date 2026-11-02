# peko-dump

Makes logical MySQL dumps in go-mydumper format and uploads them to one or more S3-compatible buckets
(S3, R2). It runs from cron on the server that holds the replica.

## What a run does

1. Takes the lock in `WORK_DIR` (waiting up to 6 hours for another run), then deletes what a killed run
   left there.
2. Copies the profile, replaces its `[mysql]` connection keys with `DB_*`, and dumps with go-mydumper.
   Everything else comes from the profile: `[where]`, `[select]`, `[filter]`, threads, chunk size.
3. Packs the dump as `<name>.<yymmddHHMM>.tar.gz` (UTC, files at the archive root).
4. Uploads it to `<prefix><file>` on every destination. Then, on each destination that got it, deletes
   the dumps older than `--keep-days` beyond the newest `--keep-at-least`, and refuses to prune when the
   newest dump there isn't fresh. A failing destination doesn't stop the others; the run exits 1.
5. Pings `--heartbeat` (healthchecks.io style) with `/start` once it holds the lock, then `/<exit status>`.

Tables are read one by one with no shared snapshot, so a dump is not a point-in-time copy. Use the
physical backup and the binlogs for disaster recovery.

## Install (Ubuntu)

```bash
sudo apt install git golang-go make pigz jq curl
git clone https://github.com/rental-ninja/peko-dump.git /opt/peko-dump
/opt/peko-dump/bin/install-mydumper
```

`install-mydumper` builds go-mydumper at a pinned commit and applies `patches/`: unpatched, it exits 0
when a SELECT dies mid-table, a file write fails, or a chunk ends on a table's last row, leaving a
truncated table in a dump reported as good.

It also needs AWS CLI v2, 2.13 or later (earlier versions ignore `endpoint_url` in a profile).

A MySQL user with `SELECT`. go-mydumper connects over TCP, so its host is `127.0.0.1`, not `localhost`:

```sql
CREATE USER 'dump'@'127.0.0.1' IDENTIFIED BY '<password>';
GRANT SELECT ON <database>.* TO 'dump'@'127.0.0.1';
```

One AWS CLI profile per destination, for the user that runs cron. Its key needs `s3:PutObject`,
`s3:ListBucket` and `s3:DeleteObject` on the prefixes.

```ini
# ~/.aws/config (keys in ~/.aws/credentials)
[profile s3]
region = eu-west-1

[profile r2]
region = auto
endpoint_url = https://<account-id>.r2.cloudflarestorage.com
```

The environment, in a file only that user can read (`chown <user> /etc/peko-dump.env`,
`chmod 600 /etc/peko-dump.env`). cron runs it with `/bin/sh`, so single-quote every value:

```bash
PATH='/usr/local/bin:/usr/bin:/bin'
DB_USER='dump'
DB_PASSWORD='<password>'
DESTINATIONS='s3:<bucket> r2:<bucket>'
# Optional: DB_HOST, DB_PORT, DB_VARS, DB_INIT_VARS, MYDUMPER, WORK_DIR (bin/peko-dump --help)
```

## Schedule

```cron
15 6 * * * set -a; . /etc/peko-dump.env; /opt/peko-dump/bin/peko-dump --profile <app>/daily_config.cnf --name <name> --prefix backups/daily/ --keep-days 120 --keep-at-least 30 --heartbeat https://hc-ping.com/<uuid> 2>&1 | logger -t peko-dump
```

- Keep the profiles in the application's repository and point `--profile` at its deployed checkout. A
  migration that adds a generated column must add it to `[filter]` in the same change, or the dumps can't
  be loaded (MySQL rejects values for generated columns).
- Never change `--name` for a prefix: whatever loads the newest dump picks it by name, and pruning only
  touches files with its own name.
- A check that must pass before a dump goes first on the same line (`<check> && /opt/peko-dump/bin/peko-dump …`).
  When it fails nothing is pinged, so the heartbeat alerts once its grace period ends.

## Restore

```bash
mkdir dump && tar -xzf <name>.<yymmddHHMM>.tar.gz -C dump
find dump -name '*.sql' ! -name '*schema-create*' -exec sed -i '1s/^/USE <database>;\n/' {} +
build/go-mydumper/bin/myloader -h <host> -P 3306 -u <user> -p <password> -d dump -t 4 -o
```

This myloader runs `USE` and the statements through a connection pool, so a statement can reach a new
connection with no database selected. The `USE` line in every file makes that rare; if it still stops
with "No database selected", rerun with `-t 1`.
