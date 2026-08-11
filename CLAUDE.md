# CLAUDE.md — johlan456/OpenArchiver fork

This is an **additive-only fork** of [LogicLabs-OU/OpenArchiver](https://github.com/LogicLabs-OU/OpenArchiver)
(AGPL-3.0), maintained for one purpose: **deploying Open Archiver without Docker.**

## Read this first

👉 **[`deploy/BARE-METAL-PLAN.md`](deploy/BARE-METAL-PLAN.md)** — the full plan: verified
codebase findings, the 5-process layout, config gotchas, and the list of scripts still to build.
Read it before doing any work in this repo.

## The one hard rule

**Never modify a file owned by upstream.**

Everything we add goes in `deploy/` (this `CLAUDE.md` is the sole exception — upstream has no
such file). Additive-only means `git merge <upstream-tag>` stays a clean fast-forward on every
release, forever. Patching an upstream file buys a merge conflict on every future upgrade.

If upstream genuinely needs a change → open a PR against upstream, don't carry a local patch.

## Remotes

```
origin    git@github.com:johlan456/OpenArchiver.git   # this fork; main = deploy branch
upstream  git@github.com:LogicLabs-OU/OpenArchiver.git
```

Currently synced to upstream tag `v0.5.2`. Upstream has a `v0.5.3-dev` branch in flight.

## Quick orientation

Ordinary pnpm monorepo — Node >= 22, pnpm 10.13.1 (pinned in root `package.json` `engines`).
No Docker-specific application code exists; the container just runs `pnpm docker-start:oss`.

Build: `pnpm install --shamefully-hoist --frozen-lockfile --prod=false` → `pnpm build:oss`
→ `pnpm db:migrate` → `pnpm start:workers` + `pnpm start:oss`

Runtime = 5 Node processes (backend :4000, frontend :3000, ingestion/indexing/scheduler workers).
External services: PostgreSQL 17, Valkey 8, Meilisearch v1.38. Tika is optional and we skip it.

## Traps that have already bitten (details in the plan doc)

- `packages/backend/src/database/migrate.ts:21` uses a **relative** migrations path — anything
  invoking it must set cwd to `packages/backend`.
- `ORIGIN` must equal `APP_URL` and both must be the **public** URL, or SvelteKit silently
  rejects form POSTs.
- `.env.example` defaults use Docker hostnames (`postgres`, `valkey`, `meilisearch`) — all must
  be rewritten to `127.0.0.1`.
- Drizzle migrations are **forward-only**. Always `pg_dump` + snapper snapshot before upgrading.

## Conventions

- Never commit secrets. Generated values live in the deployed `.env`, which stays out of git.
- Shell scripts: `set -euo pipefail`, support `--dry-run`, fail loudly with useful messages.
