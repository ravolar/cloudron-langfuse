# Langfuse for Cloudron

A [Cloudron](https://www.cloudron.io) community package for [Langfuse](https://langfuse.com), the
open-source LLM engineering platform: tracing, evaluations, prompt management, datasets and
metrics for LLM applications and agents.

This is an **unofficial** package, not affiliated with or supported by Langfuse GmbH. It is not
listed in the Cloudron App Store; install it from the URL below.

| | |
|---|---|
| Package | `io.github.ravolar.langfuse` |
| Upstream | [langfuse/langfuse](https://github.com/langfuse/langfuse) (MIT, except `ee/` directories) |
| Install URL | `https://raw.githubusercontent.com/ravolar/cloudron-langfuse/main/CloudronVersions.json` |
| Image | `ghcr.io/ravolar/cloudron-langfuse` |

## Install (no CLI needed)

In your Cloudron dashboard open **App Store → Add custom app → Community app**, paste this URL and
click **Install**:

```
https://raw.githubusercontent.com/ravolar/cloudron-langfuse/main/CloudronVersions.json
```

New versions then show up in the dashboard (app → **Updates**), like App Store apps. First steps
after installing: [Installation](#installation).

## What you get

* Langfuse's official web and worker images, unmodified, pinned by digest.
* Everything Langfuse needs in one app: PostgreSQL and Redis from Cloudron, a bundled single-node
  **ClickHouse** (traces, observations, scores) and a bundled **S3 server**
  ([Versity S3 Gateway](https://github.com/versity/versitygw), objects stored as plain files in
  `/app/data/s3`), all on loopback except the S3 media endpoint.
* Sign-in with Cloudron accounts (SSO), another OpenID Connect provider (e.g. Pocket ID), or
  email and password. Sign-up is closed by default.
* Cloudron backups, restore and clone, including ClickHouse (dumped consistently by a backup
  hook) and the S3 objects.
* Automatic packaging of new Langfuse releases: a GitHub workflow checks every 3 hours, builds,
  runs the smoke test (PostgreSQL 16 and 18: trace ingestion end to end, media upload, backup and
  restore, privilege checks) and an upgrade test with real data, and only then publishes. Updating
  an installation stays in your hands (Cloudron → app → Updates), unless you enable automatic
  updates for the app.

## Requirements

* Cloudron 10.0 or later.
* Memory: about 1.5–2.5 GB in use; the app's limit is 4 GB by default. ClickHouse sizes its own
  limit to 45% of the app's memory limit, so raise the limit (app → Resources) for larger
  volumes.
* A second subdomain for the S3 media endpoint (asked for at install, default `langfuse-media`).

## Installation

1. In the Cloudron dashboard open **App Store → Add custom app → Community app** and enter:

   ```
   https://raw.githubusercontent.com/ravolar/cloudron-langfuse/main/CloudronVersions.json
   ```

   (Optional, with the Cloudron CLI instead: `cloudron install --versions-url <url> --location langfuse.example.com`)
2. Choose the user management:
   * **Cloudron user management (SSO)**: users sign in with their Cloudron account; access is
     controlled in the app's Access Control. The first person to sign in creates the first
     organization. Nothing else to set up (`LANGFUSE_INIT_USER_EMAIL` is ignored in this mode).
   * **No Cloudron user management**: open the **File Manager**, set your email as
     `LANGFUSE_INIT_USER_EMAIL` in `/app/data/env.sh` and **restart**. The package creates that
     account as owner of a first organization. Its password:
     **Web Terminal** → `grep INITIAL_ADMIN /app/data/.secrets/secrets.env`.
3. Create a project and its API keys in Langfuse, and point your SDKs at `https://<app domain>`.

If your domain's DNS is not managed by Cloudron (provider "manual" or "no-op"), create the DNS
records for both hostnames (app and media) yourself **before** installing.

## Signing in

| Installed with | Sign-in | Sign-up |
|---|---|---|
| Cloudron user management | Cloudron accounts | any Cloudron user with access to the app; email/password off |
| Without it | email and password | closed; the first account comes from `LANGFUSE_INIT_USER_EMAIL` |

Every signed-in user can create organizations of their own; others only see the organizations
and projects they are invited to. To restrict who may create organizations, set
`LANGFUSE_ALLOWED_ORGANIZATION_CREATORS="me@example.com,..."`.

Accounts are never linked by email address (`AUTH_CUSTOM_ALLOW_ACCOUNT_LINKING=false`), so an
account at the identity provider cannot take over an existing Langfuse account with the same
address.

Without SSO, other people can only get an account while sign-up is open: set
`AUTH_DISABLE_SIGNUP="false"`, restart, let them sign up (or invite them), then remove the line
again. Langfuse sends invitation and password-reset emails through Cloudron's mail server.

**Another OpenID Connect provider** (e.g. Pocket ID) instead of Cloudron's: install without
Cloudron user management, register a client with the redirect URI
`https://<app domain>/api/auth/callback/custom` and set in `env.sh`:

```sh
AUTH_CUSTOM_CLIENT_ID="..."
AUTH_CUSTOM_CLIENT_SECRET="..."
AUTH_CUSTOM_ISSUER="https://id.example.com"
AUTH_CUSTOM_NAME="Pocket ID"
AUTH_DISABLE_SIGNUP="false"              # new users may sign in through the provider
AUTH_DISABLE_USERNAME_PASSWORD="true"    # optional: provider only
```

With sign-up open, anyone the provider authenticates gets an account, so restrict the client to
the right users at the provider. Upstream's other providers (Google, GitHub, Azure AD, Okta,
Keycloak, …) are configured the same way; see Langfuse's
[authentication docs](https://langfuse.com/self-hosting/security/authentication-and-sso).

## Configuration

Operator settings live in `/app/data/env.sh` (File Manager); **restart** the app after editing.
The file is created on first start with the common options. Only plain assignments are accepted,
one per line (`NAME="value"`; single quotes if the value contains `$`, `` ` `` or `\`). A file
with anything else (commands, `export`, CRLF line endings, control characters) is rejected and the
app does not start; the log names the offending lines.

Set by the package on every start (values in `env.sh` are ignored, and the log says so):
`DATABASE_URL`, `DIRECT_URL`, `REDIS_*`, `NEXTAUTH_URL`, the `CLICKHOUSE_*` connection, the
generated secrets (`NEXTAUTH_SECRET`, `SALT`, `ENCRYPTION_KEY`, `CLICKHOUSE_PASSWORD`), `NODE_ENV`,
`PRISMA_*`, `HOME`, `TMPDIR`.

Package defaults that `env.sh` may change: the sign-in settings above, the S3 settings
(`LANGFUSE_S3_*`), outgoing email (`SMTP_CONNECTION_URL`, `EMAIL_FROM_ADDRESS`) and
`TELEMETRY_ENABLED` (off). Everything else from Langfuse's
[configuration reference](https://langfuse.com/self-hosting/configuration) can be added.

**Old SDKs.** Langfuse v4 by default accepts traces only from current SDKs (Python v3+, JS v4+,
OpenTelemetry). If you still send from Python v2 / JS v3, set
`LANGFUSE_MIGRATION_V4_WRITE_MODE="dual"`.

### Secrets

`/app/data/.secrets/secrets.env` (root only) is generated on first start and never regenerated:

* `ENCRYPTION_KEY` encrypts the LLM API keys and integration secrets stored in Langfuse. Losing it
  makes them unreadable; it is part of the app's backups.
* `NEXTAUTH_SECRET` (sessions), `SALT` (API key hashes), `CLICKHOUSE_PASSWORD`,
  `S3_ACCESS_KEY` / `S3_SECRET_KEY` (bundled S3 server).
* `INITIAL_ADMIN_PASSWORD`: the first account's password (only used while the database has no
  users). Change it with Langfuse's password reset, which works by email, so outgoing email must
  be enabled for the app.

## Storage

| Data | Where | Backed up |
|---|---|---|
| Users, projects, prompts, API keys, settings | Cloudron PostgreSQL | Cloudron database dump |
| Traces, observations, scores | ClickHouse, `/var/lib/clickhouse` | `backup.sh` dumps it to `/app/data/clickhouse-backup` |
| Raw ingestion events, media attachments | S3 server, `/app/data/s3` | Cloudron file backup |

ClickHouse's store is a Cloudron persistent directory: it survives updates but is not copied file
by file (a live store changes constantly). Instead, Cloudron runs the package's backup hook before
each backup: it writes a consistent `BACKUP` of the Langfuse database through the running server
into `/app/data/clickhouse-backup`, which is then backed up with the rest. On restore or clone the
restore hook replaces the store with that dump, so ClickHouse always matches the restored
PostgreSQL. The dump takes disk space roughly equal to the compressed ClickHouse data (a backup of
a stopped app briefly needs about twice that, for a copy of the store).

**Media.** Multimodal attachments (images, audio, files) are uploaded and downloaded by SDKs and
browsers directly to the S3 server through short-lived presigned links on the media subdomain.
Every request must carry a valid signature; the bucket is private.

**External S3** instead of the bundled server: set the `LANGFUSE_S3_EVENT_UPLOAD_*` and
`LANGFUSE_S3_MEDIA_UPLOAD_*` variables in `env.sh` (bucket, region, endpoint, access key, secret,
`FORCE_PATH_STYLE`). Objects already in `/app/data/s3` are not moved; copy them with any S3 tool
first. The bundled server keeps running, unused.

## Updates

New Langfuse releases are picked up by the [Update Langfuse](.github/workflows/update.yml)
workflow (every 3 hours). A failed check opens a GitHub issue and publishes nothing. Langfuse runs
its PostgreSQL and ClickHouse migrations on start.

Package changes are released by running the workflow by hand with **Release package changes**.

## Security notes

* All processes run as the unprivileged `cloudron` user; `start.sh` (root) never sources files.
  `env.sh` is root-owned and only readable by the app; the secrets are root-only and handed to
  the processes by name.
* ClickHouse (stock `default` user removed) and the worker listen on loopback only. The web app
  (port 3000) and the S3 server (port 9100) are reachable through Cloudron's proxy (and, like every
  app, from other containers on the Cloudron network; S3 still needs credentials).
* ClickHouse and the S3 server get only their own credentials, never `env.sh`.
* Telemetry to Langfuse is off by default.
* The S3 server is the Versity S3 Gateway. MinIO, which other Langfuse setups bundle, is no longer
  maintained as open source and its images are no longer published.

## Development

```bash
docker build -t cloudron-langfuse:dev .
test/smoke.sh cloudron-langfuse:dev                     # PostgreSQL 16
PG_IMAGE=postgres:18-alpine test/smoke.sh cloudron-langfuse:dev
test/upgrade.sh ghcr.io/ravolar/cloudron-langfuse:<old> cloudron-langfuse:dev
```

## Credits

The way the upstream Node runtime runs on `cloudron/base`, the ClickHouse configuration and the
backup approach are adapted from [OrcVole/langfuse-cloudron](https://github.com/OrcVole/langfuse-cloudron)
(MIT). This package differs in its privilege separation, its S3 server, its sign-in defaults and
its automated release pipeline.

## License

The packaging files are MIT-licensed (see [LICENSE](LICENSE)). Langfuse, ClickHouse and the
Versity S3 Gateway are used unmodified under their own licenses.

## Support

This package is maintained on a best-effort basis. Report packaging problems as
[GitHub issues](https://github.com/ravolar/cloudron-langfuse/issues); for Langfuse itself see
[langfuse/langfuse](https://github.com/langfuse/langfuse).
