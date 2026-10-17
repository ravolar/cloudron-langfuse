#!/bin/bash
# The Langfuse web app (UI, public API, ingestion endpoint). Runs as `cloudron` through app-env.sh.
# Waits for its services, applies the PostgreSQL and ClickHouse migrations (what upstream's
# entrypoint does), creates the first account if asked to, then serves on port 3000.
set -eu

wait_for() { # <name> <command...>
    local name=$1 attempt
    shift
    for attempt in $(seq 1 90); do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt % 10 == 1 )); then echo "==> Waiting for ${name}"; fi
        sleep 2
    done
    echo "==> ERROR: ${name} is not ready after 3 minutes"
    exit 1
}

bundled_s3=false
if [[ "${LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT}" == http://127.0.0.1:9100 ]]; then
    bundled_s3=true
fi

wait_for ClickHouse curl -sf http://127.0.0.1:8123/ping
wait_for Redis env REDISCLI_AUTH="${REDIS_AUTH}" redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" ping
if [[ "${bundled_s3}" == true ]]; then
    wait_for "the S3 server" curl -s -o /dev/null http://127.0.0.1:9100/
    # Create the bucket (an existing one answers 409, which is fine).
    status=$(curl -s -o /dev/null -w '%{http_code}' -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" \
        --user "${LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID}:${LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY}" \
        "http://127.0.0.1:9100/${LANGFUSE_S3_EVENT_UPLOAD_BUCKET}")
    if [[ "${status}" != 200 && "${status}" != 409 ]]; then
        echo "==> ERROR: could not create the S3 bucket (HTTP ${status})"
        exit 1
    fi
fi

rm -f /run/langfuse/state/migrated
cd /app/code/web
prisma=/app/code/prisma-cli/build/index.js
echo "==> Applying PostgreSQL migrations"
node "${prisma}" db execute --url "${DIRECT_URL}" --file ./packages/shared/scripts/cleanup.sql
node "${prisma}" migrate deploy --schema=./packages/shared/prisma/schema.prisma
echo "==> Applying ClickHouse migrations"
(cd ./packages/shared && bash ./clickhouse/scripts/up.sh)
touch /run/langfuse/state/migrated

# The first account, without SSO: env.sh names its email and the package supplies the generated
# password, but only while the database has no users at all. Upstream's LANGFUSE_INIT_* would
# otherwise recreate the account (with that password) on every start after it was deleted.
if [[ -n "${LANGFUSE_INIT_USER_EMAIL:-}" && -z "${LANGFUSE_INIT_ORG_ID:-}" ]]; then
    users=$(psql "${DATABASE_URL}" -tAc 'SELECT count(*) FROM users')
    if [[ "${users}" == 0 ]]; then
        echo "==> Creating the first account ${LANGFUSE_INIT_USER_EMAIL}; its password is INITIAL_ADMIN_PASSWORD in /app/data/.secrets/secrets.env"
        export LANGFUSE_INIT_ORG_ID=default-org
        export LANGFUSE_INIT_ORG_NAME="${LANGFUSE_INIT_ORG_NAME:-My Organization}"
        export LANGFUSE_INIT_USER_NAME="${LANGFUSE_INIT_USER_NAME:-Admin}"
        export LANGFUSE_INIT_USER_PASSWORD="${LANGFUSE_PKG_INITIAL_ADMIN_PASSWORD}"
    else
        unset LANGFUSE_INIT_USER_EMAIL LANGFUSE_INIT_USER_NAME
    fi
fi
unset LANGFUSE_PKG_INITIAL_ADMIN_PASSWORD

echo "==> Starting the web app"
export HOSTNAME=0.0.0.0 PORT=3000
exec node ./web/server.js --keepAliveTimeout 110000
