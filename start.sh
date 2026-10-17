#!/bin/bash
# Variables are handed to the app through write_env, by name.
# shellcheck disable=SC2034
set -eu

# Langfuse on Cloudron. Runs as root for setup, then hands ClickHouse, the S3 server, the worker and
# the web app to supervisor (all drop to the `cloudron` user).
#
#   /app/data/env.sh          operator settings (sign-in, email, S3, Langfuse options); edit + restart
#   /app/data/.secrets        generated once; never regenerated (ENCRYPTION_KEY protects stored LLM keys)
#   /app/data/s3              S3 objects (trace events, media) as plain files, and their metadata
#   /var/lib/clickhouse       ClickHouse store (persistent, not in the file backup; backup.sh dumps
#                             it into /app/data/clickhouse-backup instead)

SECRETS=/app/data/.secrets/secrets.env

# Root must never act on paths the app user (cloudron) can rename or replace, or a compromised app
# could plant symlinks and steer the root steps below. So /app/data is root-owned, env.sh is
# root-owned and only readable by the app, and /run/langfuse is recreated on every start.
echo "==> Securing data directories"
chown root:root /app/data
chmod 755 /app/data
for path in /app/data/env.sh /app/data/.secrets "${SECRETS}" /app/data/s3 /app/data/clickhouse-backup; do
    if [[ -L "${path}" ]]; then
        echo "==> ERROR: ${path} is a symbolic link, which this package never creates. Refusing to start."
        echo "    Inspect it from the web terminal, remove the link and restart."
        sleep 30
        exit 1
    fi
done
if [[ -e /app/data/env.sh && ! -f /app/data/env.sh ]]; then
    echo "==> ERROR: /app/data/env.sh should be a regular file. Refusing to start."
    sleep 30
    exit 1
fi
for dir in /app/data/.secrets /app/data/s3; do
    if [[ -e "${dir}" && ! -d "${dir}" ]]; then
        echo "==> ERROR: ${dir} should be a directory. Refusing to start."
        sleep 30
        exit 1
    fi
done
mkdir -p /app/data/.secrets
chown root:root /app/data/.secrets
chmod 700 /app/data/.secrets
if [[ -L "${SECRETS}" ]] || [[ -e "${SECRETS}" && ! -f "${SECRETS}" ]]; then
    echo "==> ERROR: ${SECRETS} is not a regular file. Refusing to start."
    sleep 30
    exit 1
fi

# A restore that stopped half-way leaves its marker in the store: starting on it would serve a
# partial ClickHouse as if it were complete.
if [[ -e /var/lib/clickhouse/.restore-in-progress ]]; then
    echo "==> ERROR: the restore of the ClickHouse store did not finish. Restore the app from its backup again."
    sleep 30
    exit 1
fi
# The stores belong to the app user. Re-own a whole tree only when its top level shows that root
# (a restore) left files behind; chown -R does not follow symbolic links. The subdirectories of
# s3/ are created as the app user, so root never creates or re-owns a path the app could redirect.
mkdir -p /app/data/s3
for store in /var/lib/clickhouse /app/data/s3; do
    if [[ "$(stat -c %U "${store}")" != cloudron ]]; then
        chown -R cloudron:cloudron "${store}"
    fi
done
setpriv --reuid=cloudron --regid=cloudron --init-groups mkdir -p /app/data/s3/buckets /app/data/s3/meta

echo "==> Setting up runtime directories"
rm -rf /run/langfuse
mkdir -p /run/langfuse/home /run/langfuse/tmp /run/langfuse/state
chmod 755 /run/langfuse
chown cloudron:cloudron /run/langfuse/home /run/langfuse/tmp /run/langfuse/state

if [[ ! -f /app/data/env.sh ]]; then
    echo "==> First run: writing /app/data/env.sh template"
    cat > /app/data/env.sh <<'EOF'
# Langfuse settings. Restart the app after editing (Cloudron dashboard -> Restart).
# Reference: https://langfuse.com/self-hosting/configuration
#
# Set by the package on every start (values here are ignored): the database, Redis, ClickHouse,
# the public URL, the generated secrets (/app/data/.secrets/secrets.env), ports and paths.

# --- Sign-in ------------------------------------------------------------------------------------
# With Cloudron user management (SSO) chosen at install, people sign in with their Cloudron
# account and email/password sign-in is off. Without it, sign-in is by email and password and
# sign-up is closed: set your email here and restart, and the package creates that account once,
# as owner of a first organization. Its password is in /app/data/.secrets/secrets.env
# (INITIAL_ADMIN_PASSWORD; Web Terminal: grep INITIAL_ADMIN /app/data/.secrets/secrets.env).
LANGFUSE_INIT_USER_EMAIL=""          # e.g. "me@example.com"
# AUTH_DISABLE_SIGNUP="false"        # let anyone who can reach the app create an account
# AUTH_DISABLE_USERNAME_PASSWORD="false"   # with SSO: also allow email/password sign-in
#
# Another OpenID Connect provider (e.g. Pocket ID) instead of Cloudron's. Redirect URI to register:
#   https://<this app's domain>/api/auth/callback/custom
# AUTH_CUSTOM_CLIENT_ID=""
# AUTH_CUSTOM_CLIENT_SECRET=""
# AUTH_CUSTOM_ISSUER=""              # e.g. "https://id.example.com"
# AUTH_CUSTOM_NAME="Pocket ID"
# AUTH_DISABLE_SIGNUP="false"        # needed so new people can sign in through it

# --- External S3 instead of the bundled S3 server (optional) ---------------------------------
# The same bucket can be used for both; the media endpoint must be reachable from browsers.
# LANGFUSE_S3_EVENT_UPLOAD_BUCKET=""
# LANGFUSE_S3_EVENT_UPLOAD_REGION="auto"
# LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT=""
# LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID=""
# LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=""
# LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE="false"
# (and the same with LANGFUSE_S3_MEDIA_UPLOAD_*)

# --- Other options ---------------------------------------------------------------------------
# Delete raw ingestion events (S3 events/, full trace payloads) older than this many days, daily.
# Langfuse never deletes them itself, not even when a trace is deleted through the API.
# S3_EVENTS_RETENTION_DAYS="30"
# Accept traces from old SDKs (Python v2 / JS v3) as well; costs extra ClickHouse writes.
# LANGFUSE_MIGRATION_V4_WRITE_MODE="dual"
# TELEMETRY_ENABLED="true"           # anonymous usage statistics to Langfuse (off by default)
EOF
fi

# Both files may only contain plain assignments: NAME="value" or NAME='value', no $, backticks or
# backslashes inside double quotes, no "export", no leading spaces. env.sh is later sourced by the
# app user; anything that could run a command is refused.
check_env_file() {
    local file=$1 bad
    # Only space and tab count as blanks: grep's [[:space:]] would also accept vertical tab and
    # form feed, which bash does not treat as blanks, so "x"<VT>#$(cmd) would run cmd.
    local sp=$' \t'
    if grep -q $'\r' "${file}"; then
        echo "==> ERROR: ${file} has Windows (CRLF) line endings, which would corrupt the values."
        echo "    Re-save it with Unix (LF) line endings and restart."
        return 1
    fi
    if [[ "$(tr -d '\0' < "${file}" | wc -c)" != "$(wc -c < "${file}")" ]] ||
        LC_ALL=C grep -q $'[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]' "${file}"; then
        echo "==> ERROR: ${file} contains control characters. Remove them and restart."
        return 1
    fi
    if ! bash -n "${file}"; then
        echo "==> ERROR: ${file} has a syntax error (see above). Fix it and restart."
        return 1
    fi
    if bad=$(grep -nvE "^[${sp}]*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=(\"[^\"\$\`\\]*\"|'[^']*'|[A-Za-z0-9_./:@,+-]*)([${sp}]+#.*)?[${sp}]*$" "${file}"); then
        echo "==> ERROR: ${file} may only contain NAME=\"value\" lines (quote every value; use single"
        echo "    quotes if it contains \$, \` or a backslash; no 'export', no leading spaces). Offending lines:"
        echo "${bad}" | cut -d: -f1 | sed 's/^/    line /'
        return 1
    fi
}

# Each secret is generated once, when missing (newer package versions may add keys). The file is
# validated first, so a hand-edited line the validator would reject stops the start instead of
# making add_secret append a second, different key.
( umask 077; touch "${SECRETS}" )
chown root:root "${SECRETS}"
chmod 600 "${SECRETS}"
if ! check_env_file "${SECRETS}"; then
    sleep 30
    exit 1
fi
add_secret() {
    if ! grep -qE "^[[:blank:]]*(export[[:blank:]]+)?$1=" "${SECRETS}"; then
        echo "==> Generating $1"
        printf '%s="%s"\n' "$1" "$2" >> "${SECRETS}"
    fi
}
add_secret NEXTAUTH_SECRET "$(openssl rand -hex 32)"
add_secret SALT "$(openssl rand -hex 32)"
add_secret ENCRYPTION_KEY "$(openssl rand -hex 32)"
add_secret CLICKHOUSE_PASSWORD "$(openssl rand -hex 24)"
add_secret S3_ACCESS_KEY "langfuse$(openssl rand -hex 6)"
add_secret S3_SECRET_KEY "$(openssl rand -hex 24)"
add_secret INITIAL_ADMIN_PASSWORD "$(openssl rand -base64 18 | tr '+/' '-_')"

chown root:cloudron /app/data/env.sh
chmod 640 /app/data/env.sh
if ! check_env_file /app/data/env.sh; then
    sleep 30
    exit 1
fi

# This script runs as root and never sources a file: values like NODE_OPTIONS, LD_PRELOAD or PATH
# would affect the root-run commands below. Values it needs are read as text, by name; env.sh is
# loaded by app-env.sh, as the cloudron user, right before the web app and the worker start.
file_value() {
    # Quoted value: take what is inside the quotes (a "#" there is part of the value); unquoted:
    # drop a trailing " # comment". The validator has already restricted the line shapes.
    grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2- |
        sed -E "s/^\"([^\"]*)\".*/\1/; t; s/^'([^']*)'.*/\1/; t; s/[[:blank:]]+#.*$//"
}
for name in NEXTAUTH_SECRET SALT ENCRYPTION_KEY CLICKHOUSE_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY INITIAL_ADMIN_PASSWORD; do
    value=$(file_value "${SECRETS}" "${name}")
    if [[ ${#value} -lt 12 ]]; then
        echo "==> ERROR: ${name} is missing or too short in ${SECRETS}. Refusing to start."
        sleep 30
        exit 1
    fi
    printf -v "${name}" '%s' "${value}"
done
# Langfuse encrypts stored LLM API keys and integration secrets with it: exactly 64 hex characters.
if [[ ! "${ENCRYPTION_KEY}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "==> ERROR: ENCRYPTION_KEY in ${SECRETS} must be exactly 64 hex characters. Refusing to start."
    sleep 30
    exit 1
fi

write_env() { # <file> <owner group> NAME...: write the named variables as shell assignments
    local file=$1 owner=$2 tmp name
    shift 2
    tmp=$(mktemp "/run/langfuse/.env.XXXXXX")
    for name in "$@"; do
        printf '%s=%q\n' "${name}" "${!name}"
    done > "${tmp}"
    chown "${owner}" "${tmp}"
    chmod 640 "${tmp}"
    mv -f "${tmp}" "${file}"
}

# Fixed values for the web app and the worker, applied after env.sh so they win. Recomputed on every
# start because addon credentials and the app's domain can change.
DATABASE_URL="${CLOUDRON_POSTGRESQL_URL}"
DIRECT_URL="${CLOUDRON_POSTGRESQL_URL}"
REDIS_HOST="${CLOUDRON_REDIS_HOST}"
REDIS_PORT="${CLOUDRON_REDIS_PORT}"
REDIS_AUTH="${CLOUDRON_REDIS_PASSWORD}"
REDIS_TLS_ENABLED=false
NEXTAUTH_URL="${CLOUDRON_APP_ORIGIN}"
CLICKHOUSE_URL=http://127.0.0.1:8123
CLICKHOUSE_MIGRATION_URL=clickhouse://127.0.0.1:9000
CLICKHOUSE_USER=clickhouse
CLICKHOUSE_DB=default
CLICKHOUSE_CLUSTER_ENABLED=false
LANGFUSE_PKG_INITIAL_ADMIN_PASSWORD="${INITIAL_ADMIN_PASSWORD}"
HOME=/run/langfuse/home
TMPDIR=/run/langfuse/tmp
# The image's ENV does not survive the clean environment supervisor starts with.
NODE_ENV=production
NEXT_TELEMETRY_DISABLED=1
PRISMA_QUERY_ENGINE_LIBRARY=/app/code/.engines/query-engine.so.node
PRISMA_SCHEMA_ENGINE_BINARY=/app/code/.engines/schema-engine
fixed=(NODE_ENV NEXT_TELEMETRY_DISABLED PRISMA_QUERY_ENGINE_LIBRARY PRISMA_SCHEMA_ENGINE_BINARY DATABASE_URL DIRECT_URL REDIS_HOST REDIS_PORT REDIS_AUTH REDIS_TLS_ENABLED NEXTAUTH_URL
    NEXTAUTH_SECRET SALT ENCRYPTION_KEY CLICKHOUSE_URL CLICKHOUSE_MIGRATION_URL CLICKHOUSE_USER
    CLICKHOUSE_PASSWORD CLICKHOUSE_DB CLICKHOUSE_CLUSTER_ENABLED LANGFUSE_PKG_INITIAL_ADMIN_PASSWORD
    HOME TMPDIR)
write_env /run/langfuse/fixed.env root:cloudron "${fixed[@]}"

# Defaults for the web app and the worker, applied before env.sh so it can change them.
TELEMETRY_ENABLED=false
# The bundled S3 server, one private bucket for both. Media (multimodal attachments) is uploaded and
# downloaded by SDKs and browsers through presigned URLs, so its endpoint is the public media
# subdomain (Cloudron forwards it to the S3 server); event uploads stay on loopback.
S3_BUCKET=langfuse
defaults=(TELEMETRY_ENABLED)
for kind in EVENT MEDIA; do
    printf -v "LANGFUSE_S3_${kind}_UPLOAD_BUCKET" '%s' "${S3_BUCKET}"
    printf -v "LANGFUSE_S3_${kind}_UPLOAD_REGION" '%s' us-east-1
    printf -v "LANGFUSE_S3_${kind}_UPLOAD_ENDPOINT" '%s' http://127.0.0.1:9100
    printf -v "LANGFUSE_S3_${kind}_UPLOAD_ACCESS_KEY_ID" '%s' "${S3_ACCESS_KEY}"
    printf -v "LANGFUSE_S3_${kind}_UPLOAD_SECRET_ACCESS_KEY" '%s' "${S3_SECRET_KEY}"
    printf -v "LANGFUSE_S3_${kind}_UPLOAD_FORCE_PATH_STYLE" '%s' true
    defaults+=("LANGFUSE_S3_${kind}_UPLOAD_BUCKET" "LANGFUSE_S3_${kind}_UPLOAD_REGION"
        "LANGFUSE_S3_${kind}_UPLOAD_ENDPOINT" "LANGFUSE_S3_${kind}_UPLOAD_ACCESS_KEY_ID"
        "LANGFUSE_S3_${kind}_UPLOAD_SECRET_ACCESS_KEY" "LANGFUSE_S3_${kind}_UPLOAD_FORCE_PATH_STYLE")
done
LANGFUSE_S3_EVENT_UPLOAD_PREFIX=events/
LANGFUSE_S3_MEDIA_UPLOAD_PREFIX=media/
defaults+=(LANGFUSE_S3_EVENT_UPLOAD_PREFIX LANGFUSE_S3_MEDIA_UPLOAD_PREFIX)
if [[ -n "${LANGFUSE_MEDIA_DOMAIN:-}" ]]; then
    LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT="https://${LANGFUSE_MEDIA_DOMAIN}"
else
    echo "==> WARNING: no media domain is set: multimodal attachments will not load in browsers."
fi
# Langfuse's own media operations (deletions, reads) go to the S3 server on loopback; presigned
# links are still signed for the public endpoint. Not set when env.sh points media elsewhere:
# upstream treats an empty value as set, so it could not be cleared there.
if ! grep -qE '^LANGFUSE_S3_MEDIA_UPLOAD_(INTERNAL_)?ENDPOINT=' /app/data/env.sh; then
    LANGFUSE_S3_MEDIA_UPLOAD_INTERNAL_ENDPOINT=http://127.0.0.1:9100
    defaults+=(LANGFUSE_S3_MEDIA_UPLOAD_INTERNAL_ENDPOINT)
fi

# Sign-in. With Cloudron's OpenID Connect (user management chosen at install), Cloudron decides who
# may use the app, so its users may create their Langfuse account on first sign-in, and the
# email/password form (which would let anyone sign up) is off. Accounts are not linked by email
# address, so a Cloudron user can never take over an existing Langfuse account.
if [[ -n "${CLOUDRON_OIDC_CLIENT_ID:-}" ]]; then
    AUTH_CUSTOM_CLIENT_ID="${CLOUDRON_OIDC_CLIENT_ID}"
    AUTH_CUSTOM_CLIENT_SECRET="${CLOUDRON_OIDC_CLIENT_SECRET}"
    AUTH_CUSTOM_ISSUER="${CLOUDRON_OIDC_ISSUER}"
    AUTH_CUSTOM_NAME="${CLOUDRON_OIDC_PROVIDER_NAME:-Cloudron}"
    AUTH_CUSTOM_SCOPE="openid email profile"
    AUTH_CUSTOM_ALLOW_ACCOUNT_LINKING=false
    AUTH_DISABLE_SIGNUP=false
    AUTH_DISABLE_USERNAME_PASSWORD=true
    defaults+=(AUTH_CUSTOM_CLIENT_ID AUTH_CUSTOM_CLIENT_SECRET AUTH_CUSTOM_ISSUER AUTH_CUSTOM_NAME
        AUTH_CUSTOM_SCOPE AUTH_CUSTOM_ALLOW_ACCOUNT_LINKING)
else
    AUTH_DISABLE_SIGNUP=true
    AUTH_DISABLE_USERNAME_PASSWORD=false
fi
defaults+=(AUTH_DISABLE_SIGNUP AUTH_DISABLE_USERNAME_PASSWORD)

# Outgoing email (password resets, invitations) through Cloudron's mail server (sendmail addon;
# absent if outbound mail is disabled for the app). The STARTTLS port: the mail server's
# certificate is issued for the dashboard domain, not for the internal host name, so it is not
# verified; the connection stays encrypted and never leaves Cloudron's internal network.
if [[ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]]; then
    uri() { jq -rn --arg s "$1" '$s | @uri'; }
    SMTP_CONNECTION_URL="smtp://$(uri "${CLOUDRON_MAIL_SMTP_USERNAME}"):$(uri "${CLOUDRON_MAIL_SMTP_PASSWORD}")@${CLOUDRON_MAIL_SMTP_SERVER}:${CLOUDRON_MAIL_STARTTLS_PORT:-2587}/?requireTLS=true&tls.rejectUnauthorized=false"
    if [[ -n "${CLOUDRON_MAIL_FROM_DISPLAY_NAME:-}" ]]; then
        EMAIL_FROM_ADDRESS="${CLOUDRON_MAIL_FROM_DISPLAY_NAME} <${CLOUDRON_MAIL_FROM}>"
    else
        EMAIL_FROM_ADDRESS="Langfuse <${CLOUDRON_MAIL_FROM}>"
    fi
    defaults+=(SMTP_CONNECTION_URL EMAIL_FROM_ADDRESS)
fi
write_env /run/langfuse/defaults.env root:cloudron "${defaults[@]}"

# ClickHouse and the S3 server get only their own credentials, never env.sh.
ROOT_ACCESS_KEY="${S3_ACCESS_KEY}"
ROOT_SECRET_KEY="${S3_SECRET_KEY}"
write_env /run/langfuse/services.env root:cloudron CLICKHOUSE_PASSWORD ROOT_ACCESS_KEY ROOT_SECRET_KEY HOME TMPDIR

env_value() { file_value /app/data/env.sh "$1"; }

# Warnings only: read the values as text, without evaluating env.sh.
for name in "${fixed[@]}"; do
    if grep -qE "^${name}=" /app/data/env.sh; then
        case "${name}" in
            NEXTAUTH_SECRET|SALT|ENCRYPTION_KEY|CLICKHOUSE_PASSWORD)
                echo "==> NOTE: ${name} in /app/data/env.sh is ignored: it lives in ${SECRETS}." ;;
            *)
                echo "==> NOTE: ${name} in /app/data/env.sh is ignored: it is set by the package." ;;
        esac
    fi
done
if [[ "$(env_value AUTH_DISABLE_SIGNUP)" == false && -z "${CLOUDRON_OIDC_CLIENT_ID:-}" && -z "$(env_value AUTH_CUSTOM_CLIENT_ID)" ]]; then
    echo "==> WARNING: sign-up is open: anyone who can reach this app can create an account."
fi
if [[ -z "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]]; then
    echo "==> NOTE: outbound email is disabled: no password resets or invitation emails."
fi

echo "==> Waiting for PostgreSQL"
for attempt in $(seq 1 60); do
    if pg_isready -q -h "${CLOUDRON_POSTGRESQL_HOST}" -p "${CLOUDRON_POSTGRESQL_PORT}" \
        -U "${CLOUDRON_POSTGRESQL_USERNAME}" -d "${CLOUDRON_POSTGRESQL_DATABASE}"; then
        break
    fi
    if [[ ${attempt} == 60 ]]; then
        echo "==> ERROR: PostgreSQL did not become ready in 2 minutes; exiting so Cloudron restarts the app."
        exit 1
    fi
    echo "==> PostgreSQL not ready yet (${attempt}/60)"
    sleep 2
done

# The web app applies the PostgreSQL and ClickHouse migrations (web.sh) before it serves; the worker
# waits for that. Supervisor starts with a clean environment: this script's secrets and Cloudron's
# addon credentials would otherwise be inherited by every program. The programs get what they need
# through app-env.sh.
echo "==> Starting Langfuse"
exec env -i PATH="${PATH}" LANG=C.UTF-8 \
    /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf --nodaemon
