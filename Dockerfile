# Langfuse for Cloudron.
#
# Langfuse's official web and worker images, copied unmodified (pinned by version and digest; the
# update workflow bumps both together), plus a bundled single-node ClickHouse and an S3 server, under
# supervisor on the Cloudron base image:
#
#   web         ghcr.io/langfuse/langfuse          Next.js, port 3000 (public), runs the migrations
#   worker      ghcr.io/langfuse/langfuse-worker   ingestion queue -> ClickHouse, 127.0.0.1:3030
#   clickhouse  clickhouse/clickhouse-server       127.0.0.1:8123/9000, store in /var/lib/clickhouse
#   s3          versity/versitygw                  S3 on :9100 (also the public media subdomain),
#                                                  objects as plain files in /app/data/s3
#
# The way the upstream Node runs on cloudron/base (RHEL node + libnode + ICU data + rhel Prisma
# engines) and the ClickHouse setup are adapted from OrcVole's langfuse-cloudron (MIT),
# https://github.com/OrcVole/langfuse-cloudron.

FROM ghcr.io/langfuse/langfuse:4.70.0@sha256:932a46dfab770f89ecb2ec35258b6b80d3be8773403981a64d271ff0a408deef AS web
FROM ghcr.io/langfuse/langfuse-worker:4.70.0@sha256:3b3b204fa72fd02d010ab90c667d07281e4b9ec3b5b0b1d21470ac2624b8a564 AS worker
# Langfuse v4 recommends ClickHouse 26.4 (25.12 is the minimum).
FROM docker.io/clickhouse/clickhouse-server:26.4@sha256:c7796a1335d14385c052f10061cf719f4a368a908432ec25980860b1333e9ccd AS clickhouse
# Versity S3 Gateway (Apache-2.0): a maintained S3 server over a plain directory, a static binary.
FROM docker.io/versity/versitygw:v1.9.0@sha256:eb7f786fcd91e72194e48fcf1ac16302d686bf8e3a71434bdbc067a6efd3fdc7 AS s3

FROM docker.io/cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b

# cloudron/base has no Node.js. The upstream images run RHEL's Node 24 (a small launcher, libnode
# and a separate ICU data file at a compiled-in path); all glibc, so it runs on the base's newer
# glibc. Without the ICU data Intl.Segmenter segfaults.
COPY --from=web /usr/bin/node /usr/local/bin/node
COPY --from=web /lib64/libnode.so.137 /usr/local/lib/libnode.so.137
COPY --from=web /usr/share/node-24/icudata /usr/share/node-24/icudata
RUN ldconfig

# Each tree keeps the upstream /app layout, so paths relative to the working directory match.
COPY --from=web /app /app/code/web
COPY --from=worker /app /app/code/worker
COPY --from=web /usr/local/lib/node_modules/prisma /app/code/prisma-cli
COPY --from=web /usr/bin/migrate /usr/bin/migrate

# Prisma would pick a Debian engine on this Ubuntu base; the images carry only the rhel-openssl-3.0.x
# engines, which run fine here. Stable symlinks, so a moved engine path never needs an env change.
RUN set -eu; mkdir -p /app/code/.engines; \
    qe="$(find /app/code/web -name 'libquery_engine-rhel-openssl-3.0.x.so.node' | head -1)"; \
    se="$(find /app/code/prisma-cli /app/code/web -name 'schema-engine-rhel-openssl-3.0.x' -type f | head -1)"; \
    [ -n "${qe}" ] && [ -n "${se}" ] || { echo "rhel Prisma engines not found"; exit 1; }; \
    ln -s "${qe}" /app/code/.engines/query-engine.so.node; \
    ln -s "${se}" /app/code/.engines/schema-engine
ENV PRISMA_QUERY_ENGINE_LIBRARY=/app/code/.engines/query-engine.so.node \
    PRISMA_SCHEMA_ENGINE_BINARY=/app/code/.engines/schema-engine

COPY --from=clickhouse /usr/bin/clickhouse /usr/bin/clickhouse
COPY --from=clickhouse /etc/clickhouse-server /etc/clickhouse-server
# Upstream's docker config listens on 0.0.0.0; ours (config.d/cloudron.xml) on loopback only.
RUN rm -f /etc/clickhouse-server/config.d/docker_related_config.xml \
    && ln -s /usr/bin/clickhouse /usr/bin/clickhouse-server \
    && ln -s /usr/bin/clickhouse /usr/bin/clickhouse-client \
    && ln -s /usr/bin/clickhouse /usr/bin/clickhouse-local
COPY conf/clickhouse/config.d/cloudron.xml /etc/clickhouse-server/config.d/cloudron.xml
COPY conf/clickhouse/users.d/cloudron-user.xml /etc/clickhouse-server/users.d/cloudron-user.xml
COPY conf/clickhouse/backups.xml /etc/clickhouse-server/backups.xml
COPY --from=s3 /usr/local/bin/versitygw /usr/local/bin/versitygw
# The persistentDir (Cloudron mounts it; it also exists for plain docker runs).
RUN mkdir -p /var/lib/clickhouse && chown cloudron:cloudron /var/lib/clickhouse

# Build-time gates: fail here, not on a user's server.
RUN set -eu; \
    if ldd /usr/local/bin/node /usr/local/lib/libnode.so.137 /app/code/.engines/query-engine.so.node \
        /app/code/.engines/schema-engine /usr/bin/clickhouse 2>&1 | grep -i 'not found'; then exit 1; fi; \
    node -p "'node ' + process.versions.node + ', openssl ' + process.versions.openssl"; \
    node -e "if ([...new Intl.Segmenter('en', { granularity: 'word' }).segment('hi there')].length < 3) process.exit(1)"; \
    node /app/code/prisma-cli/build/index.js --version; \
    /app/code/.engines/schema-engine --version; \
    /usr/bin/migrate -version; \
    clickhouse --version; \
    versitygw --version; \
    rsync --version | head -1; \
    test -f /app/code/web/web/server.js; \
    test -f /app/code/worker/worker/dist/index.js; \
    test -f /app/code/web/packages/shared/prisma/schema.prisma; \
    test -f /app/code/web/packages/shared/clickhouse/scripts/up.sh
# Every napi-rs native module must load under this Node; one that does not kills the worker at start.
RUN set -eu; n=0; \
    for idx in $(grep -rl --include=index.js isMuslFromFilesystem /app/code/web /app/code/worker || true); do \
        node -e "require('${idx}')" || { echo "native module fails to load: ${idx}"; exit 1; }; \
        n=$((n + 1)); \
    done; \
    echo "native modules loaded: ${n}"; [ "${n}" -ge 2 ]

# Supervisor's own log and child logs default to /var/log, which is read-only on Cloudron.
RUN sed -e 's,^logfile=.*$,logfile=/run/supervisord.log,' \
        -e 's,^childlogdir=.*$,childlogdir=/run,' \
        -e 's,^\[supervisord\]$,[supervisord]\nuser=root,' \
        -i /etc/supervisor/supervisord.conf

ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
COPY start.sh app-env.sh web.sh worker.sh backup.sh restore.sh retention.sh /app/pkg/
COPY supervisor/ /etc/supervisor/conf.d/
# Explicit modes: the build context can arrive with 0600 files (Cloudron's on-server build).
RUN chmod 0755 /app/pkg /app/pkg/*.sh \
    && chmod 0644 /etc/supervisor/conf.d/*.conf /etc/clickhouse-server/config.d/cloudron.xml \
        /etc/clickhouse-server/users.d/cloudron-user.xml /etc/clickhouse-server/backups.xml

CMD [ "/app/pkg/start.sh" ]
