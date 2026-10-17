#!/bin/bash
# Cloudron restoreCommand. Runs as root in a temporary container from this image, before the app
# starts, after Cloudron has put the backed-up /app/data in place (restore, clone or import).
# Replaces the ClickHouse store (/var/lib/clickhouse, a persistentDir) with the dump backup.sh saved
# in /app/data/clickhouse-backup, so it matches the restored PostgreSQL and S3 objects. A marker in
# the store stays until the restore has finished; start.sh refuses to start while it is there.
# Adapted from OrcVole's langfuse-cloudron (MIT).
set -euo pipefail

CH_STORE=/var/lib/clickhouse
DUMP=/app/data/clickhouse-backup
MARKER=.restore-in-progress

log() { echo "==> [restore] $*"; }
as_app() { setpriv --reuid=cloudron --regid=cloudron --init-groups "$@"; }

if [[ -L "${DUMP}" ]]; then
    log "ERROR: ${DUMP} is a symbolic link, which this package never creates"
    exit 1
fi

touch "${CH_STORE}/${MARKER}"
find "${CH_STORE}" -mindepth 1 -maxdepth 1 ! -name "${MARKER}" -exec rm -rf {} +
chown cloudron:cloudron "${CH_STORE}"

if [[ -d "${DUMP}" ]]; then
    log "restoring ClickHouse"
    # RESTORE must go through a real server: a store written by `clickhouse local` lacks the
    # metadata the server expects. A throwaway password; the server listens on loopback only.
    CLICKHOUSE_PASSWORD=$(openssl rand -hex 24)
    export CLICKHOUSE_PASSWORD
    as_app env HOME=/tmp /usr/bin/clickhouse-server --config-file=/etc/clickhouse-server/config.xml \
        > /tmp/restore-clickhouse.log 2>&1 &
    server=$!
    stop_server() { kill -TERM "${server}" 2>/dev/null || true; wait "${server}" 2>/dev/null || true; }
    trap stop_server EXIT
    for attempt in $(seq 1 90); do
        if curl -sf http://127.0.0.1:8123/ping >/dev/null 2>&1; then break; fi
        if [[ ${attempt} == 90 ]]; then
            log "ERROR: the temporary ClickHouse did not start"
            tail -20 /tmp/restore-clickhouse.log
            exit 1
        fi
        sleep 1
    done
    # The server runs as `cloudron` and reads the dump, which backup.sh made root-owned.
    chmod -R a+rX "${DUMP}"
    clickhouse-client --host 127.0.0.1 --user clickhouse \
        --query "RESTORE DATABASE default FROM File('clickhouse-backup/dump') SETTINGS allow_different_database_def=1, allow_different_table_def=1" >/dev/null
    stop_server
    trap - EXIT
    log "ClickHouse restored: $(du -sh "${CH_STORE}" | cut -f1)"
else
    log "no ClickHouse dump in the backup; the app creates its tables on start"
fi
chown -R cloudron:cloudron "${CH_STORE}"
rm -f "${CH_STORE}/${MARKER}"
log "restore complete"
