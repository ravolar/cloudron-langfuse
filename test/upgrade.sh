#!/bin/bash
# Upgrade test: what a Cloudron update does to a running installation. Start the old image, create
# real data (first account, project and API keys, a trace, a media object, a prompt), then replace
# the container with the new image on the same /app/data, ClickHouse store and database, and check
# that the update kept everything: migrations, sign-in, API keys, traces, media, prompts, secrets.
#
#   test/upgrade.sh <old image> <new image>
#
# PG_IMAGE selects the PostgreSQL version (default postgres:16-alpine). Needs docker, curl and jq.
# Leaves nothing behind.
set -euo pipefail

OLD_IMAGE=${1:?usage: test/upgrade.sh <old image> <new image>}
NEW_IMAGE=${2:?usage: test/upgrade.sh <old image> <new image>}
PG_IMAGE=${PG_IMAGE:-postgres:16-alpine}
ID="langfuseupgrade$$"
PORT=${UPGRADE_PORT:-18610}
S3PORT=$((PORT + 1))
ORIGIN="http://localhost:${PORT}"
EMAIL="admin@example.com"
PK=pk-lf-upgrade00000000000000000000000000
SK=sk-lf-upgrade00000000000000000000000000
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    docker rm -f "${ID}-app" "${ID}-pg" "${ID}-redis" >/dev/null 2>&1 || true
    docker volume rm "${ID}-run" "${ID}-tmp" "${ID}-ch" >/dev/null 2>&1 || true
    docker network rm "${ID}" >/dev/null 2>&1 || true
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
    docker run --rm -i -v "${WORK}/data:/d" --entrypoint sh "${NEW_IMAGE}" -c "$1"
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
auth() { printf '%s:%s' "${PK}" "${SK}" | base64 -w0; }
api() { curl -s -H "Authorization: Basic $(auth)" -H 'Content-Type: application/json' "$@"; }

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
        "$1" >/dev/null
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

login() {
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
cat > "${WORK}/data/env.sh" <<EOF
LANGFUSE_INIT_USER_EMAIL="${EMAIL}"
LANGFUSE_INIT_PROJECT_ID="upgrade"
LANGFUSE_INIT_PROJECT_NAME="Upgrade"
LANGFUSE_INIT_PROJECT_PUBLIC_KEY="${PK}"
LANGFUSE_INIT_PROJECT_SECRET_KEY="${SK}"
LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT="http://localhost:${S3PORT}"
EOF

echo "==> Old version: ${OLD_IMAGE}"
start_app "${OLD_IMAGE}"
if wait_ready; then pass "old version started"; else fail "old version started"; docker logs "${ID}-app" 2>&1 | tail -60; exit 1; fi
# The project and keys need the organization the first account creates; add it and restart.
echo 'LANGFUSE_INIT_ORG_ID="default-org"' | edit_env "cat >> /d/env.sh"
docker restart -t 20 "${ID}-app" >/dev/null
if wait_ready; then pass "old version restarted with a project"; else fail "old version restarted with a project"; docker logs "${ID}-app" 2>&1 | tail -60; exit 1; fi

password=$(app_exec grep '^INITIAL_ADMIN_PASSWORD=' /app/data/.secrets/secrets.env | cut -d= -f2- | tr -d '"')
check "sign-in on the old version" test "$(login "${EMAIL}" "${password}")" = "${EMAIL}"
TRACE=$(openssl rand -hex 16)
ingest "${TRACE}" >/dev/null
check "trace on the old version" trace_visible "${TRACE}"
api -o /dev/null -X POST "${ORIGIN}/api/public/v2/prompts" \
    -d '{"name":"upgrade-prompt","type":"text","prompt":"Hello {{name}}","labels":["production"]}'
check "prompt on the old version" bash -c "curl -fs -H 'Authorization: Basic $(auth)' '${ORIGIN}/api/public/v2/prompts/upgrade-prompt' | jq -e '.prompt == \"Hello {{name}}\"'"
img="${WORK}/blob.txt"
echo "media before the update $$" > "${img}"
sha=$(openssl dgst -sha256 -binary "${img}" | base64)
media=$(api -X POST "${ORIGIN}/api/public/media" \
    -d "{\"traceId\":\"${TRACE}\",\"contentType\":\"text/plain\",\"contentLength\":$(stat -c %s "${img}"),\"sha256Hash\":\"${sha}\",\"field\":\"input\"}")
media_id=$(jq -r '.mediaId // empty' <<<"${media}")
curl -s -o /dev/null -X PUT -H 'Content-Type: text/plain' -H "x-amz-checksum-sha256: ${sha}" \
    --data-binary "@${img}" "$(jq -r '.uploadUrl // empty' <<<"${media}")"
api -o /dev/null -X PATCH "${ORIGIN}/api/public/media/${media_id}" \
    -d "{\"uploadedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"uploadHttpStatus\":200}"
check "media on the old version" bash -c "curl -fs \"\$(curl -s -H 'Authorization: Basic $(auth)' '${ORIGIN}/api/public/media/${media_id}' | jq -r .url)\" | cmp -s - '${img}'"
secrets_before=$(app_exec sha256sum /app/data/.secrets/secrets.env)

echo "==> Update to: ${NEW_IMAGE}"
docker stop -t 20 "${ID}-app" >/dev/null
docker rm "${ID}-app" >/dev/null
start_app "${NEW_IMAGE}"
if wait_ready; then pass "new version started on the old data"; else fail "new version started on the old data"; docker logs "${ID}-app" 2>&1 | tail -80; exit 1; fi

check "secrets unchanged" test "$(app_exec sha256sum /app/data/.secrets/secrets.env)" = "${secrets_before}"
check "sign-in still works" test "$(login "${EMAIL}" "${password}")" = "${EMAIL}"
check "still exactly one user" test "$(docker exec "${ID}-pg" psql -U lfuser -d lfdb -tAc 'select count(*) from users')" = 1
check "API keys still authenticate" bash -c "curl -fs -H 'Authorization: Basic $(auth)' '${ORIGIN}/api/public/projects' | jq -e '.data[0].id == \"upgrade\"'"
check "trace from before the update" trace_visible "${TRACE}"
check "prompt from before the update" bash -c "curl -fs -H 'Authorization: Basic $(auth)' '${ORIGIN}/api/public/v2/prompts/upgrade-prompt' | jq -e '.prompt == \"Hello {{name}}\"'"
check "media from before the update" bash -c "curl -fs \"\$(curl -s -H 'Authorization: Basic $(auth)' '${ORIGIN}/api/public/media/${media_id}' | jq -r .url)\" | cmp -s - '${img}'"
TRACE2=$(openssl rand -hex 16)
ingest "${TRACE2}" >/dev/null
check "ingestion after the update" trace_visible "${TRACE2}"

if [[ ${FAILED} != 0 ]]; then
    echo "==> UPGRADE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -40
    exit 1
fi
echo "==> Upgrade test passed"
