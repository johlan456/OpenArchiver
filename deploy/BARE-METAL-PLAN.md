# Open Archiver — Bare-Metal (Non-Docker) Deployment Plan

Status: **planning complete, scripts not yet written.**
Written 2026-08-11 against upstream tag `v0.5.2` (commit `a560b8c`).

This document is the full context for building a non-Docker deployment of Open Archiver.
It records what was verified in the codebase, the decisions taken, and the work remaining.

---

## 1. Why this exists

Upstream ships **Docker only**. Every install path in the repo is containerised:

- `docker-compose.yml`
- `open-archiver.yml` (Coolify)
- `apps/open-archiver/Dockerfile`
- `docs/user-guides/installation.md` — Docker Compose start to finish
- `README.md` — "Deployment: Docker Compose deployment"

A grep across the repo for `bare.?metal|without docker|systemd|kubernetes|helm|pm2` returns
nothing relevant. **There is no supported non-Docker install, and no upstream support for one.**

We need one anyway (operator preference: no Docker).

## 2. Why it is nevertheless viable

The container is thin. `apps/open-archiver/Dockerfile` ends with
`CMD ["pnpm", "docker-start:oss"]` — a plain root-`package.json` script. There is **no
Docker-specific application code anywhere**. The whole thing is an ordinary pnpm monorepo:
Node 22 + Express backend + SvelteKit (node adapter) frontend.

Running it outside Docker is a packaging exercise, not a porting exercise.

## 3. What actually runs — 5 Node processes

From root `package.json`:

| Process | Command | Port |
| --- | --- | --- |
| Backend API | `node apps/open-archiver/dist/index.js` | 4000 (`PORT_BACKEND`) |
| Frontend (SvelteKit node adapter) | `node packages/frontend/build/index.js` | 3000 (`PORT_FRONTEND`) |
| Ingestion worker | `node packages/backend/dist/workers/ingestion.worker.js` | — |
| Indexing worker | `node packages/backend/dist/workers/indexing.worker.js` | — |
| Sync scheduler | `node packages/backend/dist/jobs/schedulers/sync-scheduler.js` | — |

Root script groupings that wrap these:

- `pnpm start:oss` → backend + frontend (via `concurrently`)
- `pnpm start:workers` → the 3 workers
- `pnpm docker-start:oss` → both of the above; this is what the container runs

→ **5 systemd units**, bound together by a `.target`.

## 4. External services

Versions as pinned in `docker-compose.yml`. Install natively from distro repos / upstream releases.

| Service | Version | Required? |
| --- | --- | --- |
| PostgreSQL | 17 | yes |
| Valkey (or Redis) | 8 | yes — BullMQ job queue |
| Meilisearch | v1.38 | yes — search index |
| Apache Tika | 3.2.2 | **optional** — needs a JVM |

**Tika is genuinely optional.** Verified in `packages/backend/src/helpers/textExtractor.ts:144`
and `packages/backend/src/services/OcrService.ts:245`: if `TIKA_URL` is unset the app falls back
to bundled pure-JS parsers (`pdf2json`, `mammoth`, `xlsx`).

Cost of skipping Tika:
- narrower attachment format coverage for full-text indexing
- max extractable file size drops 100 MB → 50 MB (`textExtractor.ts:135`)
- `PDF_PARSE_TIMEOUT_MS` (default 20000) applies only in this fallback path

Decision: **start without Tika.** Avoids a JVM on the host. Revisit if attachment search
coverage proves insufficient.

## 5. Install sequence (derived from Dockerfile + docker/docker-entrypoint.sh)

```bash
pnpm install --shamefully-hoist --frozen-lockfile --prod=false
pnpm build:oss
cp .env.example .env            # then edit — see §6
pnpm db:migrate                 # entrypoint does this in Docker; NOT automatic otherwise
pnpm start:workers &
pnpm start:oss
```

Toolchain is pinned in root `package.json` `engines`: Node `>=22.0.0`, pnpm `10.13.1`.

### Native modules are a non-issue

Root `package.json` sets `pnpm.onlyBuiltDependencies: ["esbuild"]` — no dependency's install
script runs except esbuild's. **No node-gyp, no `base-devel`, no Python required.**

- `pst-extractor` is pure JS.
- `sqlite3` is declared in `packages/backend/package.json` but has **zero references anywhere
  in `src/`** — a dead dependency, never loaded. Its native build script is blocked and that
  is harmless.

## 6. Configuration gotchas

### `.env.example.docker` does not exist

`docs/user-guides/installation.md` instructs `cp .env.example.docker .env`. That file is not in
the repo. Only `.env.example` exists. Upstream docs bug — see §9.

### Docker hostnames must be rewritten

`.env.example` defaults point at Docker service names. All must become `127.0.0.1`:

```
DATABASE_URL="postgresql://admin:password@postgres:5432/open_archive"  →  @127.0.0.1:5432
REDIS_HOST=valkey                                                      →  127.0.0.1
MEILI_HOST=http://meilisearch:7700                                     →  http://127.0.0.1:7700
TIKA_URL=http://tika:9998                                              →  unset entirely (§4)
```

### `ORIGIN` must equal `APP_URL`, and both must be the *public* URL

SvelteKit's node adapter rejects form POSTs with a CSRF error when `ORIGIN` does not match the
browser's actual origin. Behind a reverse proxy set both to e.g.
`https://archive.example.com` — **not** `localhost:3000`. `APP_URL` is separately read by the
backend for CORS.

Failure mode is misleading: login appears to work, everything else silently breaks.
The install script should assert `ORIGIN == APP_URL` and refuse to continue otherwise.

### Secrets to generate (never commit these)

- `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `MEILI_MASTER_KEY`
- `JWT_SECRET` — long random string
- `ENCRYPTION_KEY` — `openssl rand -hex 32` (DB field encryption)
- `STORAGE_ENCRYPTION_KEY` — `openssl rand -hex 32` (optional but recommended; emails/attachments at rest)

`STORAGE_LOCAL_ROOT_PATH` (default `/var/data/open-archiver`) must exist and be writable by the
service user before first start.

### Migrations are cwd-sensitive — important for systemd

`packages/backend/src/database/migrate.ts:21` passes a **relative** path:

```ts
await migrate(db, { migrationsFolder: 'src/database/migrations' });
```

The root `pnpm db:migrate` works because `pnpm --filter` sets the cwd to `packages/backend`.
A systemd unit or script invoking `node dist/database/migrate.js` directly **must** set
`WorkingDirectory=<repo>/packages/backend` or migrations fail to resolve.

Migrations are drizzle, **forward-only** — no down-migrations. Always snapshot the DB first.

## 7. Repository strategy — additive-only fork

Fork: `johlan456/OpenArchiver` (this repo). Remotes:

```
origin    git@github.com:johlan456/OpenArchiver.git
upstream  git@github.com:LogicLabs-OU/OpenArchiver.git
```

**The rule: never modify an upstream-owned file.** Everything we add lives under `deploy/`
(plus a root `CLAUDE.md`, which upstream does not have).

Why: as long as our changes are purely additive to new paths, `git merge v0.5.3` is always a
clean fast-forward with zero conflicts, every release, forever. The moment we patch an upstream
file we inherit a merge conflict on every future upgrade.

If an upstream change is genuinely needed → send it upstream as a PR (§9), don't carry a patch.

`main` in this fork is the deploy branch: upstream tags get merged into it. Upstream is
currently at tag `v0.5.2`; there is a `v0.5.3-dev` branch on upstream, so a v0.5.3 release is
in flight.

### Licence

Upstream is **AGPL-3.0** (verified: `LICENSE` is the full 650-line AGPLv3 text).

Forking and modifying is fine. One compliance note for the record: AGPL §13 gives users
interacting with a modified version over a network the right to its source. Deploy-only
additions carry low practical risk, but keeping this fork public costs nothing and removes the
question entirely.

## 8. Work remaining — what to build

Everything below goes in `deploy/`.

### 8.1 `deploy/install.sh`
- preflight: Node >= 22, pnpm 10.13.1, `psql`/valkey/meilisearch reachable
- create service user + `STORAGE_LOCAL_ROOT_PATH` with correct ownership
- generate secrets, render `.env` from `.env.example` with localhost hosts
- **assert `ORIGIN == APP_URL`**
- `pnpm install --frozen-lockfile` → `pnpm build:oss` → `pnpm db:migrate`
- install + enable systemd units
- Should follow the house style: `set -euo pipefail`, `--dry-run` support, clear error handling.

### 8.2 `deploy/systemd/` — 5 units + 1 target
- `openarchiver-backend.service`, `openarchiver-frontend.service`,
  `openarchiver-ingestion.service`, `openarchiver-indexing.service`,
  `openarchiver-scheduler.service`, `openarchiver.target`
- `EnvironmentFile=` pointing at the deployed `.env`
- correct `WorkingDirectory` per unit (see §6 migrations note)
- `After=postgresql.service valkey.service meilisearch.service`
- restart policy + a non-root `User=`

### 8.3 `deploy/upgrade.sh <tag>`
The most valuable piece. Sequence:

1. `pg_dump` snapshot **and** snapper snapshot before touching anything
2. `git fetch upstream --tags && git merge <tag>`
3. **diff `.env.example` between old and new tag; abort on unhandled new keys** — this is the
   main drift risk (see §10)
4. `pnpm install --frozen-lockfile && pnpm build:oss`
5. `pnpm db:migrate`
6. `systemctl restart openarchiver.target`
7. health check; documented rollback path on failure

### 8.4 `deploy/backup.sh`
`pg_dump` + Meilisearch snapshot (`MEILI_SCHEDULE_SNAPSHOT` is set to 86400 in compose) +
`STORAGE_LOCAL_ROOT_PATH`. Feed into the existing restic/snapshot chain rather than inventing
a new one.

### 8.5 Reverse proxy notes
Caddy in front of :3000, with `ORIGIN`/`APP_URL` set to the public URL.

## 9. Upstream contribution opportunity

Two things worth PRing back once our setup works:

1. **Fix the `.env.example.docker` reference** in `docs/user-guides/installation.md` (§6) —
   a one-line docs bug.
2. **Contribute a bare-metal install guide.** If merged, this deployment shape becomes
   semi-supported upstream and future changes account for it — which directly shrinks our
   maintenance burden.

## 10. Standing risks

| Risk | Mitigation |
| --- | --- |
| **Config drift** — new env vars per release land silently. v0.5.2 added `LOG_LEVEL`, `PDF_PARSE_TIMEOUT_MS`, `INGESTION_WORKER_CONCURRENCY`, journaling vars. Docker users inherit new defaults; we do not. | `upgrade.sh` diffs `.env.example` between tags and refuses to proceed on unhandled new keys (§8.3) |
| **No upstream support** — troubleshooting/upgrade docs all assume `docker compose pull` | Accepted. Offset by §9 |
| **Forward-only migrations** | Mandatory `pg_dump` + snapper snapshot before every upgrade |
| **Merge conflicts on upgrade** | Additive-only discipline (§7) |
| **Meilisearch major upgrades** need their own procedure | See `docs/user-guides/upgrade-and-migration/meilisearch-upgrade.md` |
