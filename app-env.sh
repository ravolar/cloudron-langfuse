#!/bin/bash
# Starts a Langfuse process with its environment. Runs as the `cloudron` user (supervisor's user=),
# never as root: operator settings from /app/data/env.sh can contain anything the validator
# accepts, including NODE_OPTIONS, LD_PRELOAD or PATH, so they must only ever reach processes
# that already run with the app's own privileges.
#
#   app-env.sh COMMAND...             web app / worker: package defaults, then env.sh, then the
#                                     secrets and platform values written by start.sh (they win)
#   app-env.sh --service COMMAND...   ClickHouse / the S3 server: only their own credentials
set -eu

set +u
set -o allexport
if [[ "$1" == --service ]]; then
    shift
    # shellcheck disable=SC1091
    source /run/langfuse/services.env
else
    # shellcheck disable=SC1091
    source /run/langfuse/defaults.env
    # shellcheck disable=SC1091
    source /app/data/env.sh
    # shellcheck disable=SC1091
    source /run/langfuse/fixed.env
fi
set +o allexport
set -u

exec "$@"
