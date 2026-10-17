#!/bin/bash
# Deletes Langfuse's raw ingestion events (the S3 event files under events/) older than
# S3_EVENTS_RETENTION_DAYS from the bundled S3 server. Langfuse keeps them forever otherwise, even
# after the trace is deleted through the API (OTLP batches are not tracked per trace), and the
# bundled S3 server has no lifecycle rules. Runs as `cloudron` through app-env.sh: once at start,
# then every 24 hours. Media (media/) is not touched.
set -eu

idle() { exec sleep infinity; }  # nothing to do: stay up so supervisor does not restart us

days=${S3_EVENTS_RETENTION_DAYS:-}
if [[ -z "${days}" ]]; then
    echo "==> Raw event retention is off (S3_EVENTS_RETENTION_DAYS is not set): event files are kept"
    idle
fi
if [[ ! "${days}" =~ ^[0-9]+$ ]] || (( days < 1 )); then
    echo "==> ERROR: S3_EVENTS_RETENTION_DAYS must be a whole number of days, at least 1; raw events are NOT being deleted"
    idle
fi
if [[ "${LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT}" != http://127.0.0.1:9100 ]]; then
    echo "==> NOTE: events go to an external S3 service: set S3_EVENTS_RETENTION_DAYS as a lifecycle rule there instead"
    idle
fi
bucket=${LANGFUSE_S3_EVENT_UPLOAD_BUCKET}
prefix=${LANGFUSE_S3_EVENT_UPLOAD_PREFIX%/}
# Never delete outside the events prefix: no empty prefix, no "..", only plain path characters.
if [[ ! "${bucket}" =~ ^[A-Za-z0-9._-]+$ || ! "${prefix}" =~ ^[A-Za-z0-9._/-]+$ || "${prefix}" == *..* ]]; then
    echo "==> ERROR: unexpected event bucket or prefix ('${bucket}' / '${prefix}'); raw events are NOT being deleted"
    idle
fi
objects=/app/data/s3/buckets/${bucket}
meta=/app/data/s3/meta/${bucket}

echo "==> Raw event retention: deleting ${bucket}/${prefix}/ files older than ${days} days, daily"
while true; do
    deleted=0
    if [[ -d "${objects}/${prefix}" ]]; then
        while IFS= read -r -d '' file; do
            key=${file#"${objects}/"}
            rm -f -- "${file}"
            rm -rf -- "${meta:?}/${key}"
            deleted=$((deleted + 1))
        done < <(find "${objects}/${prefix}" -type f -mmin +$((days * 1440)) -print0)
        find "${objects}/${prefix}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        if [[ -d "${meta}/${prefix}" ]]; then
            find "${meta}/${prefix}" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        fi
    fi
    echo "==> Raw event retention: deleted ${deleted} event files older than ${days} days"
    sleep 86400 &
    wait $!
done
