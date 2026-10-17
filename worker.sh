#!/bin/bash
# The Langfuse worker (ingestion queue -> ClickHouse, evaluations, exports). Runs as `cloudron`
# through app-env.sh, once the web app has applied the migrations.
set -eu

unset LANGFUSE_PKG_INITIAL_ADMIN_PASSWORD LANGFUSE_INIT_USER_PASSWORD
for attempt in $(seq 1 150); do
    if [[ -f /run/langfuse/state/migrated ]]; then
        break
    fi
    if (( attempt % 15 == 1 )); then echo "==> Worker waiting for the migrations"; fi
    if [[ ${attempt} == 150 ]]; then
        echo "==> ERROR: the migrations did not complete in 5 minutes"
        exit 1
    fi
    sleep 2
done

cd /app/code/worker
export HOSTNAME=127.0.0.1 PORT=3030
exec node worker/dist/index.js
