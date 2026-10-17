#!/bin/bash
# Cloudron backupCommand. Runs as root in a temporary container from this image, sharing the app's
# network namespace, with /app/data and the persistentDirs mounted, while the app keeps running.
# Puts a consistent ClickHouse BACKUP of the `default` database (all Langfuse tables) into
# /app/data/clickhouse-backup, which Cloudron then backs up with the rest of /app/data (including
# the S3 objects in /app/data/s3, copied after this dump, and PostgreSQL, dumped after that).
# Approach adapted from OrcVole's langfuse-cloudron (MIT); this version dumps through the running
# server instead of a snapshot when it can.
set -euo pipefail

CH_STORE=/var/lib/clickhouse
DUMP=/app/data/clickhouse-backup
SECRETS=/app/data/.secrets/secrets.env

log() { echo "==> [backup] $*"; }

if [[ -e "${CH_STORE}/.restore-in-progress" ]]; then
    log "ERROR: the ClickHouse store is being restored; not backing up an incomplete store"
    exit 1
fi
for path in "${DUMP}" "${DUMP}.new"; do
    if [[ -L "${path}" ]]; then
        log "ERROR: ${path} is a symbolic link, which this package never creates"
        exit 1
    fi
done

rm -rf "${DUMP}.new" /app/data/.clickhouse-snapshot
if [[ ! -d "${CH_STORE}/metadata" ]]; then
    log "ClickHouse store is empty; nothing to dump"
    rm -rf "${DUMP}"
elif curl -sf http://127.0.0.1:8123/ping >/dev/null 2>&1; then
    # The app is running: let its server write a consistent BACKUP. It runs as `cloudron`, so it
    # gets a directory of its own; the result is made root-owned before it is published.
    log "dumping ClickHouse through the running server"
    password=$(grep -E '^CLICKHOUSE_PASSWORD=' "${SECRETS}" | tail -n 1 | cut -d= -f2- | tr -d "\"'")
    mkdir "${DUMP}.new"
    chown cloudron:cloudron "${DUMP}.new"
    CLICKHOUSE_PASSWORD="${password}" clickhouse-client --host 127.0.0.1 --user clickhouse \
        --query "BACKUP DATABASE default TO File('clickhouse-backup.new/dump')" >/dev/null
    chown -R root:root "${DUMP}.new"
else
    # A running server holds a lock on <store>/status. Locked but not answering (restarting,
    # crash-looping): copying a store that is being written would not give a consistent dump.
    if [[ -f "${CH_STORE}/status" && ! -L "${CH_STORE}/status" ]] && ! flock -n "${CH_STORE}/status" true; then
        log "ERROR: ClickHouse is running but not answering; retry the backup once the app is healthy"
        exit 1
    fi
    # The app is stopped: dump from a copy of the store with `clickhouse local` (reading the store
    # in place would write to it), as the app user, since the copy is the app's data.
    log "app is not running; dumping ClickHouse from a copy of its store"
    snap=/app/data/.clickhouse-snapshot
    rc=0
    rsync -a --exclude=/status --exclude=/tmp/ --exclude=/shadow/ "${CH_STORE}/" "${snap}/" || rc=$?
    if [[ ${rc} != 0 && ${rc} != 24 ]]; then
        log "ERROR: copying the ClickHouse store failed (rsync exit ${rc})"
        rm -rf "${snap}"
        exit 1
    fi
    mkdir "${DUMP}.new"
    chown -R cloudron:cloudron "${snap}" "${DUMP}.new"
    (cd /app/data && setpriv --reuid=cloudron --regid=cloudron --init-groups env HOME=/tmp \
        clickhouse local --path="${snap}" --config-file=/etc/clickhouse-server/backups.xml \
        --query "BACKUP DATABASE default TO File('clickhouse-backup.new/dump')" >/dev/null)
    rm -rf "${snap}"
    chown -R root:root "${DUMP}.new"
fi
if [[ -d "${DUMP}.new" ]]; then
    rm -rf "${DUMP}"
    mv "${DUMP}.new" "${DUMP}"
    log "ClickHouse dump: $(du -sh "${DUMP}" | cut -f1)"
fi
