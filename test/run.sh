#!/bin/bash
# Exercises a dump run, with and without --recipient, against stand-ins for MySQL Shell and the AWS CLI.
# docker run --rm -v "$PWD:/peko:ro" ubuntu:24.04 bash /peko/test/run.sh
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq jq pigz age >/dev/null || exit 9
export PATH=/peko/test/fake:$PATH MYSQLSH=/peko/test/fake/mysqlsh WORK_DIR=/tmp/work DB_USER=u DB_PASSWORD=p DESTINATIONS='r2:b'
printf '[mysql]\ndatabase = ninja\nthreads = 1\nchunksize = 1\n' >/tmp/p.cnf
age-keygen -o /tmp/id.txt 2>/dev/null; R=$(age-keygen -y /tmp/id.txt)
mkdir -p /buckets/b/backups/daily
for d in 300 200 100; do f=/buckets/b/backups/daily/ninja.$(date -u -d "$d days ago" +%y%m%d%H%M).tar.gz; echo old >"$f"; touch -d "$d days ago" "$f"; done
f=/buckets/b/backups/daily/ninja.$(date -u -d '150 days ago' +%y%m%d%H%M).tar.gz.age; echo old >"$f"; touch -d '150 days ago' "$f"
pass=0; fail=0; check() { if eval "$2"; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
P=/peko/bin/peko-dump; A=(--profile /tmp/p.cnf --name ninja --prefix backups/daily/ --keep-days 120 --keep-at-least 1)
$P "${A[@]}" >/tmp/plain.log 2>&1; check "plain run exits 0" '[ $? -eq 0 ]'
check "plain archive is .tar.gz" 'ls /buckets/b/backups/daily | grep -qE "^ninja\.[0-9]{10}\.tar\.gz$"'
sleep 61
$P "${A[@]}" --recipient "$R" >/tmp/enc.log 2>&1; check "encrypted run exits 0" '[ $? -eq 0 ]'
new=$(ls /buckets/b/backups/daily | grep -E '\.tar\.gz\.age$' | sort | tail -1)
check "encrypted archive is .tar.gz.age" '[ -n "$new" ] && ! tar -tzf "/buckets/b/backups/daily/$new" >/dev/null 2>&1'
check "decrypts and lists @.done.json" 'age -d -i /tmp/id.txt "/buckets/b/backups/daily/$new" | tar -tz | grep -q "@.done.json"'
check "prune removed the .tar.gz and .tar.gz.age past 120 days, kept the rest" '[ "$(ls /buckets/b/backups/daily | wc -l)" -eq 3 ] && ! ls /buckets/b/backups/daily | grep -q "$(date -u -d "150 days ago" +%y%m%d)"'
check "no plaintext archive left in work dir" '! find /tmp/work -name "*.tar.gz" | grep -q .'
$P "${A[@]}" --recipient AGE-SECRET-KEY-1ABC >/tmp/bad.log 2>&1; check "rejects a non-public key" '[ $? -eq 1 ] && grep -q "AGE-SECRET-" /tmp/bad.log && ! grep -q "1ABC" /tmp/bad.log'
f=/buckets/b/backups/daily/ninja.$(date -u -d '130 days ago' +%y%m%d%H%M).tar.gz.age; echo old >"$f"; touch -d '130 days ago' "$f"; sleep 61
FAIL_DELETE=1 $P "${A[@]}" --recipient "$R" >/tmp/lock.log 2>&1; check "locked delete fails the run" '[ $? -eq 1 ] && grep -q ObjectLockedByBucketPolicy /tmp/lock.log'
echo "passed=$pass failed=$fail"; [ $fail -eq 0 ]
