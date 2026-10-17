#!/bin/bash
# Smoke test: run the package image the way Cloudron does (read-only root filesystem; /app/data,
# /run, /tmp and the ClickHouse persistentDir writable) next to PostgreSQL and Redis, and check:
#   - Langfuse comes up healthy and the first account (created by the package) can sign in
#   - a trace sent with API keys goes web -> Redis -> worker -> ClickHouse and S3 and reads back
#   - media upload through a presigned URL to the bundled S3 server
#   - backup.sh / restore.sh (Cloudron's backupCommand / restoreCommand), with the app running
#     and stopped, roll ClickHouse back to the backup
#   - the package's privilege separation
#
#   test/smoke.sh <image>
#
# PG_IMAGE selects the PostgreSQL version (default postgres:16-alpine, like Cloudron 10.0; Cloudron
# 10.1 runs PostgreSQL 18). Needs docker, curl and jq. Leaves nothing behind.
set -euo pipefail

IMAGE=${1:?usage: test/smoke.sh <image>}
PG_IMAGE=${PG_IMAGE:-postgres:16-alpine}
ID="langfusesmoke$$"
PORT=${SMOKE_PORT:-18600}
S3PORT=$((PORT + 1))
ORIGIN="http://localhost:${PORT}"
EMAIL="admin@example.com"
PK=pk-lf-smoke0000000000000000000000000000
SK=sk-lf-smoke0000000000000000000000000000
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    docker rm -f "${ID}-app" "${ID}-pg" "${ID}-redis" >/dev/null 2>&1 || true
    docker volume rm "${ID}-run" "${ID}-tmp" "${ID}-ch" >/dev/null 2>&1 || true
    docker network rm "${ID}" >/dev/null 2>&1 || true
    # the data dir is root-owned after start.sh ran; remove it from a container
    docker run --rm -v "${WORK}:/w" --entrypoint sh "${PG_IMAGE}" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
    rmdir "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi; }
app_exec() { docker exec "${ID}-app" "$@"; }
# /app/data belongs to root once the app has started (and this test may not run as root): edit
# env.sh from a container.
edit_env() { # <sh script operating on /d/env.sh>; stdin is passed through
    docker run --rm -i -v "${WORK}/data:/d" --entrypoint sh "${IMAGE}" -c "$1"
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
auth() { printf '%s:%s' "${PK}" "${SK}" | base64 -w0; }
# Environment of the oldest process whose command line matches $1 (not this probe), read as the
# app user.
proc_env() {
    docker exec -u cloudron "${ID}-app" bash -c 'tr "\0" "\n" < "/proc/$(pgrep -o -f -- "$1")/environ"' _ "$1"
}
web_has_env_sh() { proc_env '^next-server' | grep -qx SMOKE_MARKER=from-env-sh; }
clickhouse_env_clean() {
    local env
    env=$(proc_env '^/usr/bin/clickhouse-server')
    grep -q '^CLICKHOUSE_PASSWORD=' <<<"${env}" && ! grep -qE '^(SMOKE_MARKER|ENCRYPTION_KEY|DATABASE_URL)=' <<<"${env}"
}
s3_env_clean() {
    local env
    env=$(proc_env '^/usr/local/bin/versitygw')
    grep -q '^ROOT_SECRET_KEY=' <<<"${env}" && ! grep -qE '^(SMOKE_MARKER|ENCRYPTION_KEY|DATABASE_URL)=' <<<"${env}"
}
worker_env_clean() {
    local env
    env=$(proc_env '^node worker/dist/index.js')
    grep -q '^CLICKHOUSE_URL=' <<<"${env}" && ! grep -qE '^(LANGFUSE_PKG_INITIAL_ADMIN_PASSWORD|LANGFUSE_INIT_USER_PASSWORD)=' <<<"${env}"
}

echo "==> Starting PostgreSQL (${PG_IMAGE}) and Redis"
docker network create "${ID}" >/dev/null
docker run -d --name "${ID}-pg" --network "${ID}" \
    -e POSTGRES_USER=lfuser -e POSTGRES_PASSWORD=pgpass -e POSTGRES_DB=lfdb "${PG_IMAGE}" >/dev/null
docker run -d --name "${ID}-redis" --network "${ID}" redis:7-alpine redis-server --requirepass redispw >/dev/null
for _ in $(seq 1 60); do
    docker exec "${ID}-pg" pg_isready -q -U lfuser -d lfdb >/dev/null 2>&1 && break
    sleep 1
done
sleep 2

mkdir -p "${WORK}/data"
# The operator's first edit without SSO (POSTINSTALL): name the first account. SMOKE_MARKER shows
# which processes get env.sh.
printf 'LANGFUSE_INIT_USER_EMAIL="%s"\nSMOKE_MARKER="from-env-sh"\n' "${EMAIL}" > "${WORK}/data/env.sh"
# A NUL byte (bash would silently drop it) must be refused.
printf 'NUL="a\0b"\n' >> "${WORK}/data/env.sh"

start_app() {
    docker run -d --name "${ID}-app" --network "${ID}" --read-only \
        -p "127.0.0.1:${PORT}:3000" -p "127.0.0.1:${S3PORT}:9100" \
        -v "${WORK}/data:/app/data" -v "${ID}-run:/run" -v "${ID}-tmp:/tmp" -v "${ID}-ch:/var/lib/clickhouse" \
        -e CLOUDRON_APP_ORIGIN="${ORIGIN}" \
        -e CLOUDRON_POSTGRESQL_URL="postgres://lfuser:pgpass@${ID}-pg:5432/lfdb" \
        -e CLOUDRON_POSTGRESQL_HOST="${ID}-pg" -e CLOUDRON_POSTGRESQL_PORT=5432 \
        -e CLOUDRON_POSTGRESQL_USERNAME=lfuser -e CLOUDRON_POSTGRESQL_PASSWORD=pgpass \
        -e CLOUDRON_POSTGRESQL_DATABASE=lfdb \
        -e CLOUDRON_REDIS_HOST="${ID}-redis" -e CLOUDRON_REDIS_PORT=6379 -e CLOUDRON_REDIS_PASSWORD=redispw \
        "${IMAGE}" >/dev/null
}

wait_ready() {
    for _ in $(seq 1 150); do
        if [[ "$(status "${ORIGIN}/api/public/health")" == 200 && "$(status "${ORIGIN}/auth/sign-in")" == 200 ]]; then
            return 0
        fi
        logs=$(docker logs "${ID}-app" 2>&1)  # captured first: `docker logs | grep -q` under pipefail can SIGPIPE
        if grep -qE "Refusing to start|==> ERROR|entered FATAL" <<<"${logs}"; then
            return 1
        fi
        sleep 2
    done
    return 1
}

stop_app() { docker stop -t 20 "${ID}-app" >/dev/null; docker rm "${ID}-app" >/dev/null; }

# Cloudron runs backupCommand in a temporary container sharing the app's network namespace (when it
# runs), and restoreCommand in one before the app starts; both with a read-only image.
run_tool() { # <network> <script>
    docker run --rm --read-only --network "$1" --tmpfs /tmp --tmpfs /run \
        -v "${WORK}/data:/app/data" -v "${ID}-ch:/var/lib/clickhouse" "${IMAGE}" "$2"
}

login() { # prints the signed-in email
    local jar csrf
    jar=$(mktemp)
    csrf=$(curl -s -c "${jar}" -b "${jar}" "${ORIGIN}/api/auth/csrf" | jq -r .csrfToken)
    curl -s -c "${jar}" -b "${jar}" -o /dev/null -X POST "${ORIGIN}/api/auth/callback/credentials" \
        --data-urlencode "csrfToken=${csrf}" --data-urlencode "email=$1" --data-urlencode "password=$2" \
        --data-urlencode "json=true"
    curl -s -b "${jar}" "${ORIGIN}/api/auth/session" | jq -r '.user.email // empty'
    rm -f "${jar}"
}

# A trace with one span, sent the way current SDKs do (OTLP/HTTP JSON). Langfuse v4 rejects
# trace events on the legacy /api/public/ingestion endpoint by default.
ingest() { # <32-hex trace id>
    local now
    now=$(date +%s%N)
    curl -s -o /dev/null -w '%{http_code}' -X POST "${ORIGIN}/api/public/otel/v1/traces" \
        -H "Authorization: Basic $(auth)" -H 'Content-Type: application/json' \
        -d "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"smoke\"}}]},\"scopeSpans\":[{\"scope\":{\"name\":\"smoke\"},\"spans\":[{\"traceId\":\"$1\",\"spanId\":\"${1:0:16}\",\"name\":\"smoke-span\",\"kind\":1,\"startTimeUnixNano\":\"${now}\",\"endTimeUnixNano\":\"$((now + 1000000))\",\"attributes\":[{\"key\":\"langfuse.observation.input\",\"value\":{\"stringValue\":\"hello\"}}]}]}]}]}"
}

observations() { # <trace id>: number of observations readable through the public API
    curl -s -H "Authorization: Basic $(auth)" "${ORIGIN}/api/public/v2/observations?traceId=$1" | jq '.data | length'
}

trace_visible() { # <trace id>: readable within ~60 s
    for _ in $(seq 1 30); do
        if [[ "$(observations "$1")" == 1 ]]; then return 0; fi
        sleep 2
    done
    return 1
}

trace_gone() { [[ "$(observations "$1")" == 0 ]]; }

run_checks() {
    check "healthy (/api/public/health)" test "$(status "${ORIGIN}/api/public/health")" = 200
    check "worker healthy" app_exec curl -sf http://127.0.0.1:3030/api/health
    check "sign-in page renders" test "$(status "${ORIGIN}/auth/sign-in")" = 200
    check "sign-up closed" bash -c "curl -s -X POST -H 'Content-Type: application/json' -d '{\"name\":\"x\",\"email\":\"intruder@example.com\",\"password\":\"Password123!x\"}' '${ORIGIN}/api/auth/signup' | grep -qi 'disabled'"
    check "ClickHouse on loopback only" bash -c "docker exec ${ID}-app cat /proc/net/tcp /proc/net/tcp6 | awk '\$4 == \"0A\" {print \$2}' | grep -iE ':(1FBB|2328)\$' | grep -viE '^(0100007F|00000000000000000000000001000000):' | wc -l | grep -qx 0"
    check "worker on loopback only" bash -c "docker exec ${ID}-app cat /proc/net/tcp | awk '\$4 == \"0A\" {print \$2}' | grep -qx '0100007F:0BD6'"
    check "ClickHouse default user removed" bash -c "[ \"\$(docker exec ${ID}-app curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8123/?query=SELECT+1')\" != 200 ]"
    check "/app/data is root-owned" test "$(app_exec stat -c %U:%a /app/data)" = "root:755"
    check "env.sh readable by the app only via group" test "$(app_exec stat -c %U:%G:%a /app/data/env.sh)" = "root:cloudron:640"
    check "secrets are root-only" test "$(app_exec stat -c %U:%a /app/data/.secrets/secrets.env)" = "root:600"
    check "app user cannot read the secrets" bash -c "! docker exec -u cloudron ${ID}-app cat /app/data/.secrets/secrets.env"
    check "app user cannot write env.sh" bash -c "! docker exec -u cloudron ${ID}-app sh -c 'echo x >> /app/data/env.sh'"
    check "S3 store owned by the app user" test "$(app_exec stat -c %U /app/data/s3/buckets)" = "cloudron"
    check "supervisor does not carry addon credentials" bash -c "! docker exec ${ID}-app cat /proc/1/environ | tr '\\\\0' '\\\\n' | grep -qE '^(CLOUDRON_POSTGRESQL_PASSWORD|CLOUDRON_REDIS_PASSWORD|DATABASE_URL|ENCRYPTION_KEY)='"
    check "web app gets env.sh" web_has_env_sh
    check "ClickHouse gets neither env.sh nor app secrets" clickhouse_env_clean
    check "S3 server gets neither env.sh nor app secrets" s3_env_clean
    check "first-account password not passed to the worker" worker_env_clean
    check "all processes run as the app user (uid 1000)" test "$(app_exec bash -c 'for p in /proc/[0-9]*; do case "$(cat "$p/comm" 2>/dev/null)" in node|clickhouse*|versitygw) awk "/^Uid:/{print \$2}" "$p/status";; esac; done | sort -u | tr -d "\n"')" = "1000"
}

echo "==> Refuses a NUL byte in env.sh"
start_app
sleep 8
check "NUL byte in env.sh refused" bash -c "docker logs ${ID}-app 2>&1 | grep -q 'contains control characters'"
docker rm -f "${ID}-app" >/dev/null
edit_env "sed -i '/^NUL=/d' /d/env.sh"

echo "==> First start"
start_app
if wait_ready; then pass "app started"; else fail "app started"; docker logs "${ID}-app" 2>&1 | tail -80; exit 1; fi
run_checks

echo "==> First account"
password=$(app_exec grep '^INITIAL_ADMIN_PASSWORD=' /app/data/.secrets/secrets.env | cut -d= -f2- | tr -d '"')
check "first account created by the package can sign in" test "$(login "${EMAIL}" "${password}")" = "${EMAIL}"
check "wrong password is refused" test -z "$(login "${EMAIL}" "wrong-password-123")"
check "first account owns the first organization" bash -c "docker exec ${ID}-pg psql -U lfuser -d lfdb -tAc \"select m.role from organization_memberships m join users u on u.id = m.user_id where u.email = '${EMAIL}'\" | grep -qx OWNER"

echo "==> Project and API keys (upstream LANGFUSE_INIT_*), restart"
edit_env "cat >> /d/env.sh" <<EOF
LANGFUSE_INIT_ORG_ID="default-org"
LANGFUSE_INIT_PROJECT_ID="smoke"
LANGFUSE_INIT_PROJECT_NAME="Smoke"
LANGFUSE_INIT_PROJECT_PUBLIC_KEY="${PK}"
LANGFUSE_INIT_PROJECT_SECRET_KEY="${SK}"
LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT="http://localhost:${S3PORT}"
LANGFUSE_S3_MEDIA_UPLOAD_INTERNAL_ENDPOINT="http://127.0.0.1:9100"
EOF
stop_app
start_app
if wait_ready; then pass "app restarted"; else fail "app restarted"; docker logs "${ID}-app" 2>&1 | tail -60; exit 1; fi
check "API keys authenticate" bash -c "curl -fs -H 'Authorization: Basic $(auth)' '${ORIGIN}/api/public/projects' | jq -e '.data[0].id == \"smoke\"'"
check "still exactly one user (first account not recreated)" test "$(docker exec "${ID}-pg" psql -U lfuser -d lfdb -tAc 'select count(*) from users')" = 1

echo "==> Tracing"
T1=$(openssl rand -hex 16)
check "OTLP ingestion accepted" test "$(ingest "${T1}")" = 200
check "trace reads back (web -> Redis -> worker -> ClickHouse)" trace_visible "${T1}"
check "event stored in the bundled S3 (/app/data/s3)" bash -c "docker exec ${ID}-app find /app/data/s3/buckets/langfuse/events -type f | grep -q ."
check "no lock files in the S3 store" bash -c "! docker exec ${ID}-app test -e /app/data/s3/buckets/.vgwlocks"
check "S3 metadata in the sidecar directory (no xattrs)" bash -c "docker exec ${ID}-app find /app/data/s3/meta -type f | grep -q ."

echo "==> Raw event retention"
# An event file from 40 days ago (backdated copy of a real one) must go, today's must stay.
docker exec -u cloudron "${ID}-app" bash -c 'f=$(find /app/data/s3/buckets/langfuse/events -type f | head -1); \
    old=/app/data/s3/buckets/langfuse/events/otel/retention-test/2000/01/01/00/00/old.json; \
    mkdir -p "$(dirname "${old}")" /app/data/s3/meta/langfuse/events/otel/retention-test/2000/01/01/00/00/old.json/meta && cp "${f}" "${old}" && touch -d "40 days ago" "${old}"'
echo 'S3_EVENTS_RETENTION_DAYS="30"' | edit_env "cat >> /d/env.sh"
stop_app
start_app
if wait_ready; then pass "app restarted with retention"; else fail "app restarted with retention"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi
sleep 3
check "retention reports its run" bash -c "docker logs ${ID}-app 2>&1 | grep -q 'Raw event retention: deleted 1 event files older than 30 days'"
check "old event file deleted" bash -c "! docker exec ${ID}-app test -e /app/data/s3/buckets/langfuse/events/otel/retention-test/2000/01/01/00/00/old.json"
check "its metadata and empty directories deleted" bash -c "! docker exec ${ID}-app test -e /app/data/s3/meta/langfuse/events/otel/retention-test && ! docker exec ${ID}-app test -e /app/data/s3/buckets/langfuse/events/otel/retention-test"
check "recent event files kept" bash -c "docker exec ${ID}-app find /app/data/s3/buckets/langfuse/events -type f | grep -q ."
check "trace still readable (ClickHouse untouched)" trace_visible "${T1}"

echo "==> Media upload (presigned URL)"
img="${WORK}/pixel.png"
printf '\x89PNG\r\n\x1a\n\0\0\0\rIHDR\0\0\0\x01\0\0\0\x01\x08\x06\0\0\0\x1f\x15\xc4\x89\0\0\0\rIDATx\x9cc\xf8\xff\xff?\0\x05\xfe\x02\xfe\xa7\x35\x81\x84\0\0\0\0IEND\xaeB`\x82' > "${img}"
sha=$(openssl dgst -sha256 -binary "${img}" | base64)
size=$(stat -c %s "${img}")
media=$(curl -s -X POST "${ORIGIN}/api/public/media" -H "Authorization: Basic $(auth)" -H 'Content-Type: application/json' \
    -d "{\"traceId\":\"${T1}\",\"contentType\":\"image/png\",\"contentLength\":${size},\"sha256Hash\":\"${sha}\",\"field\":\"input\"}")
upload_url=$(jq -r '.uploadUrl // empty' <<<"${media}")
media_id=$(jq -r '.mediaId // empty' <<<"${media}")
check "presigned upload URL points at the media endpoint" bash -c "[[ \$1 == http://localhost:${S3PORT}/* ]]" _ "${upload_url}"
put=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: image/png' -H "x-amz-checksum-sha256: ${sha}" \
    --data-binary "@${img}" "${upload_url}")
check "upload through the presigned URL" test "${put}" = 200
curl -s -o /dev/null -X PATCH "${ORIGIN}/api/public/media/${media_id}" -H "Authorization: Basic $(auth)" -H 'Content-Type: application/json' \
    -d "{\"uploadedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"uploadHttpStatus\":200}"
download=$(curl -s "${ORIGIN}/api/public/media/${media_id}" -H "Authorization: Basic $(auth)" | jq -r '.url // empty')
check "download through the presigned URL" bash -c "curl -fs '${download}' | cmp -s - '${img}'"
check "bucket is private (anonymous read refused)" test "$(status "http://localhost:${S3PORT}/langfuse/")" = 403

echo "==> Backup with the app running, then restore (Cloudron's backupCommand / restoreCommand)"
if run_tool "container:${ID}-app" /app/pkg/backup.sh >"${WORK}/backup.log" 2>&1; then pass "backup.sh (app running)"; else fail "backup.sh (app running)"; cat "${WORK}/backup.log"; fi
check "backup dumped through the running server" grep -q "through the running server" "${WORK}/backup.log"
check "dump is root-owned" test "$(app_exec stat -c %U /app/data/clickhouse-backup)" = root
T2=$(openssl rand -hex 16)
ingest "${T2}" >/dev/null
check "trace after the backup reads back" trace_visible "${T2}"
stop_app
if run_tool "${ID}" /app/pkg/restore.sh >"${WORK}/restore.log" 2>&1; then pass "restore.sh"; else fail "restore.sh"; cat "${WORK}/restore.log"; fi
start_app
if wait_ready; then pass "app started on the restored store"; else fail "app started on the restored store"; docker logs "${ID}-app" 2>&1 | tail -60; exit 1; fi
check "trace from before the backup is back" trace_visible "${T1}"
check "trace from after the backup is gone (store rolled back)" trace_gone "${T2}"
check "ingestion works after the restore" test "$(ingest "${T2}")" = 200
check "... and reads back" trace_visible "${T2}"

echo "==> Backup with the app stopped, then restore"
stop_app
if run_tool none /app/pkg/backup.sh >"${WORK}/backup2.log" 2>&1; then pass "backup.sh (app stopped)"; else fail "backup.sh (app stopped)"; cat "${WORK}/backup2.log"; fi
check "backup dumped from a copy of the store" grep -q "from a copy of its store" "${WORK}/backup2.log"
check "no snapshot left behind" bash -c "! docker run --rm -v '${WORK}/data:/d' --entrypoint ls '${IMAGE}' -d /d/.clickhouse-snapshot"
if run_tool "${ID}" /app/pkg/restore.sh >"${WORK}/restore2.log" 2>&1; then pass "restore.sh"; else fail "restore.sh"; cat "${WORK}/restore2.log"; fi
start_app
if wait_ready; then pass "app started on the restored store"; else fail "app started on the restored store"; docker logs "${ID}-app" 2>&1 | tail -60; exit 1; fi
check "trace 1 is there" trace_visible "${T1}"
check "trace 2 is there" trace_visible "${T2}"
run_checks

echo "==> Refuses to start on a broken env.sh or an interrupted restore"
stop_app
echo 'BROKEN=$(id)' | edit_env "cat >> /d/env.sh"
start_app
sleep 8
check "command substitution in env.sh refused" bash -c "docker logs ${ID}-app 2>&1 | grep -q 'may only contain NAME='"
stop_app
edit_env "sed -i '/^BROKEN=/d' /d/env.sh"
docker run --rm -v "${ID}-ch:/c" --entrypoint touch "${IMAGE}" /c/.restore-in-progress
start_app
sleep 8
check "interrupted restore refused" bash -c "docker logs ${ID}-app 2>&1 | grep -q 'restore of the ClickHouse store did not finish'"

if [[ ${FAILED} != 0 ]]; then
    echo "==> SMOKE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -40
    exit 1
fi
echo "==> Smoke test passed"
