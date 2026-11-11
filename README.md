# peko-dump

Makes logical MySQL dumps with MySQL Shell and uploads them to one or more S3-compatible buckets (S3, R2).
It runs from cron on the server that holds the replica.

## What a run does

1. Takes the lock in `WORK_DIR` (waiting up to 6 hours for another run), then deletes what a killed run
   left there.
2. Reads the profile and dumps the database with `util.dumpSchemas`: chunked and parallel, every chunk
   compressed with zstd. Tables, their schema and generated columns come out as they are; only the rows
   are filtered, by `[where]`.
3. Checks the dump finished (`@.done.json`) and packs it as `<name>.<yymmddHHMM>.tar.gz` (UTC, files at the
   archive root). With `--recipient age1…` (repeatable), the archive goes through age on its way to the
   disk and is named `<name>.<yymmddHHMM>.tar.gz.age`: the server and the buckets only ever hold ciphertext,
   and only the matching age identity can open it.
4. Uploads it to `<prefix><file>` on every destination. Then, on each destination that got it, deletes
   the dumps older than `--keep-days` beyond the newest `--keep-at-least`, and refuses to prune when the
   newest dump there isn't fresh. A failing destination doesn't stop the others; the run exits 1.
   Pruning counts both names. A bucket lock (R2) that still protects a dump to prune fails the run, so
   keep each lock shorter than `--keep-days`.
5. Pings `--heartbeat` (healthchecks.io style) with `/start` once it holds the lock, then `/<exit status>`.

A dump is not a point-in-time copy (`consistent: false`, so the dump user needs no lock privileges). Use a
snapshot (`--clone`, below) and the binlogs for disaster recovery.

## Snapshot (`--clone`)

With `--clone` instead of `--profile`, step 2 copies the whole instance with `CLONE LOCAL`: a physical copy of
every table at one moment, taken without a global lock (DDL waits until it ends, writes don't). The archive is
that data directory plus `peko-dump-clone.json`: when the copy began and ended, and the binlog that was current
when it began (`CLONE LOCAL` itself records no binlog position).

- It runs as root on the database server itself, with `DB_HOST=127.0.0.1`: mysqld writes the copy to its own
  disk and the files belong to `mysql`.
- `CLONE_DIR` (default `/var/lib/mysql-files`) must be a directory mysqld may write to; Ubuntu's AppArmor
  profile allows that one. The run refuses to start unless that disk has twice the data's size free (the copy
  plus its archive), and deletes the copy when it ends, also when it fails.
- The clone plugin, and a user that may clone:

```sql
INSTALL PLUGIN clone SONAME 'mysql_clone.so';
CREATE USER 'backup'@'127.0.0.1' IDENTIFIED BY '<password>';
GRANT BACKUP_ADMIN, REPLICATION CLIENT ON *.* TO 'backup'@'127.0.0.1';
GRANT SELECT ON performance_schema.clone_status TO 'backup'@'127.0.0.1';
```

## Profile

An ini file:

```ini
[mysql]
database = <database>
threads = 10
chunksize = 64          # MB per chunk

[where]
<table> = <SQL condition>   # only the rows that match; a table without a line is dumped whole
```

Other sections are ignored, except `[select]`: MySQL Shell can't replace column values, so a profile that
asks for it is refused.

## Install (Ubuntu)

```bash
sudo apt install mysql-shell pigz jq curl age   # age only for --recipient
git clone https://github.com/rental-ninja/peko-dump.git /opt/peko-dump
```

It also needs AWS CLI v2, 2.13 or later (earlier versions ignore `endpoint_url` in a profile).

A MySQL user at `127.0.0.1`, because MySQL Shell connects over TCP. Besides the database it reads the two
role tables, to check its own privileges:

```sql
CREATE USER 'dump'@'127.0.0.1' IDENTIFIED BY '<password>';
GRANT SELECT ON <database>.* TO 'dump'@'127.0.0.1';
GRANT SELECT ON mysql.role_edges TO 'dump'@'127.0.0.1';
GRANT SELECT ON mysql.default_roles TO 'dump'@'127.0.0.1';
```

Without `REPLICATION CLIENT` each dump warns that it can't record the binlog position; nothing needs it.

One AWS CLI profile per destination, for the user that runs cron. Its key needs `s3:PutObject`,
`s3:ListBucket` and `s3:DeleteObject` on the prefixes.

```ini
# ~/.aws/config (keys in ~/.aws/credentials)
[profile s3]
region = eu-west-1

[profile r2]
region = auto
endpoint_url = https://<account-id>.r2.cloudflarestorage.com   # an EU bucket: <account-id>.eu.r2…
```

The environment, in a file only that user can read (`chown <user> /etc/peko-dump.env`,
`chmod 600 /etc/peko-dump.env`). cron runs it with `/bin/sh`, so single-quote every value:

```bash
PATH='/usr/local/bin:/usr/bin:/bin'
DB_USER='dump'
DB_PASSWORD='<password>'
DESTINATIONS='s3:<bucket> r2:<bucket>'
# Optional: DB_HOST, DB_PORT, MYSQLSH, WORK_DIR (bin/peko-dump --help)
```

## Schedule

```cron
15 6 * * * set -a; . /etc/peko-dump.env; /opt/peko-dump/bin/peko-dump --profile <app>/daily_config.cnf --name <name> --prefix backups/daily/ --keep-days 120 --keep-at-least 30 --heartbeat https://hc-ping.com/<uuid> 2>&1 | logger -t peko-dump
```

- Keep the profiles in the application's repository and point `--profile` at its deployed checkout.
- Never change `--name` for a prefix: whatever loads the newest dump picks it by name, and pruning only
  touches files with its own name.
- A check that must pass before a dump goes first on the same line (`<check> && /opt/peko-dump/bin/peko-dump …`).
  When it fails nothing is pinged, so the heartbeat alerts once its grace period ends.

## Restore

```bash
mkdir dump && tar -xzf <name>.<yymmddHHMM>.tar.gz -C dump
# encrypted: age -d -i <identity file> <name>.<yymmddHHMM>.tar.gz.age | tar -xz -C dump
mysql -e "SET GLOBAL local_infile = ON; ALTER INSTANCE DISABLE INNODB REDO_LOG"
mysqlsh --host <host> --user <user> --py -e "util.load_dump('dump', {'threads': 8, 'skipBinlog': True, 'ignoreVersion': True})"
mysql -e "ALTER INSTANCE ENABLE INNODB REDO_LOG; SET GLOBAL local_infile = OFF"
```

With the redo log off the load is much faster, but a crash during it leaves an instance that won't start:
only do it on a server you can rebuild.

### Restore a snapshot

On a server with the same MySQL version, MySQL stopped:

```bash
rm -rf /var/lib/mysql && mkdir /var/lib/mysql && tar -xzf <name>.<yymmddHHMM>.tar.gz -C /var/lib/mysql
chown -R mysql:mysql /var/lib/mysql && systemctl start mysql
```

To roll it forward, replay the binlogs from `binlog_file_at_start` in `peko-dump-clone.json` up to the moment
you want. With GTIDs on, the server skips the transactions the copy already holds:

```bash
mysqlbinlog --stop-datetime='<YYYY-MM-DD HH:MM:SS>' <binlog_file_at_start> <later binlogs…> | mysql --max-allowed-packet=1G
```


## Test

```bash
docker run --rm -v "$PWD:/peko:ro" ubuntu:24.04 bash /peko/test/run.sh
```
