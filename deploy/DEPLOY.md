# Open Archiver — bare-metal deployment runbook

Target shape: **Devuan (sysvinit) + supervisor**, all services on one host.
Written for the FAFO deployment; the same runbook drives a prod build — deltas in §7.

Placeholders used throughout: `<ARCHIVE_DOMAIN>` (public FQDN), `<HOST>` (SSH target).
No real hostnames, IPs, or credentials belong in this repo — ever.

## 1. Host prerequisites

- Devuan 6+ (or Debian 13+ with sysvinit-style init), amd64
- 4 vCPU / 8 GB RAM minimum (Meilisearch indexing is the memory hog), disk sized for the mail archive
- Outbound HTTPS to: deb.devuan.org, nodejs.org, registry.npmjs.org, github.com, caddyserver.com
  - Note: github.com and dl.caddyserver.com are **IPv4-only**. An IPv6-only host needs NAT64 or a private IPv4 with NAT breakout.
- Inbound 80/443 reachable from the internet (Let's Encrypt HTTP/TLS-ALPN validation + visitors)
- DNS record for `<ARCHIVE_DOMAIN>` pointing at the host (AAAA and/or A)
- A sudo-capable login

## 2. What lands where

| Path | What |
| --- | --- |
| `/srv/openarchiver` | git checkout of this fork (`main`); also the `openarchiver` user's `$HOME` (pnpm store/cache land in dot-dirs here) |
| `/srv/openarchiver/.env` | rendered config + generated secrets, mode 600 — **never in git** |
| `/var/data/open-archiver` | archived mail + attachments (`STORAGE_LOCAL_ROOT_PATH`) |
| `/var/lib/meilisearch` | search index |
| `/var/log/openarchiver/*.log` | app + meilisearch logs (via supervisor) |
| `/var/log/caddy/` | caddy process + access logs |
| `/etc/supervisor/conf.d/{openarchiver,meilisearch,caddy}.conf` | process definitions |
| `/etc/caddy/{Caddyfile,CaddyEnv,ssl/}` | reverse proxy config + ACME state |
| `/etc/nftables.conf` | host firewall (inbound: 22/80/443 + ICMP only) |
| `/var/backups/openarchiver/` | pre-upgrade `pg_dump`s |

Process model: PostgreSQL 17 and Valkey run as normal sysvinit services (apt packages).
Supervisor runs everything that has no init script: **5 app processes** (backend :4000,
frontend :3000, ingestion/indexing workers, sync scheduler — grouped as `openarchiver:*`),
**meilisearch** (127.0.0.1:7700), and **caddy** (the only public listener; binary at
`/usr/local/bin/caddy`, ACME state under `/etc/caddy/ssl`, runs as `www-data`).

Only Caddy is reachable from outside. The browser talks solely to the frontend; the
frontend proxies `/api/*` to the backend server-side. The backend binds all interfaces
(upstream code we don't patch) — the nftables ruleset is what keeps :4000 private.

## 3. Fresh install

```bash
ssh <HOST>
sudo git clone https://github.com/johlan456/OpenArchiver.git /srv/openarchiver
cd /srv/openarchiver
sudo ./deploy/install.sh --domain <ARCHIVE_DOMAIN>     # add --dry-run to preview
```

The installer is idempotent — re-running it preserves the existing `.env` and DB
credentials. It finishes with a health check of all three HTTP surfaces.

First user: open `https://<ARCHIVE_DOMAIN>` — the app prompts to create the initial
admin account on first visit.

## 4. Upgrades

Desktop side (has GitHub + upstream access):

```bash
git fetch upstream --tags
git merge <new-tag>        # additive-only fork ⇒ always a clean fast-forward
git push origin main
```

Host side:

```bash
cd /srv/openarchiver
sudo ./deploy/upgrade.sh           # defaults to origin/main
```

`upgrade.sh` refuses to proceed when:
- the new ref is not a fast-forward (additive-only rule broken — fix on the desktop);
- the new `.env.example` contains keys missing from the deployed `.env` (config drift —
  handle each new key, or `--force-env` to accept upstream defaults).

It takes a mandatory `pg_dump` first and then **stops and waits** for the operator to
take a hypervisor snapshot — that snapshot is the only full rollback, because Drizzle
migrations are forward-only.

## 5. Operations

```bash
sudo supervisorctl status                      # everything
sudo supervisorctl restart openarchiver:*      # app only (not caddy/meili)
sudo tail -f /var/log/openarchiver/backend.log
sudo -u postgres psql open_archive
```

Config change: edit `/srv/openarchiver/.env`, then `sudo supervisorctl restart openarchiver:*`.
Caddyfile change: edit `/etc/caddy/Caddyfile`, validate
(`caddy validate --config /etc/caddy/Caddyfile --envfile /etc/caddy/CaddyEnv`), then
`sudo supervisorctl restart caddy`.

## 6. Backups

Pre-upgrade dumps land in `/var/backups/openarchiver/` automatically. For scheduled
backups, the three things that matter are:

1. `pg_dump -Fc open_archive` — the database
2. `/var/data/open-archiver` — the archive itself (encrypted at rest via `STORAGE_ENCRYPTION_KEY`)
3. `/srv/openarchiver/.env` — without it (esp. `ENCRYPTION_KEY`/`STORAGE_ENCRYPTION_KEY`), backups 1–2 are not fully restorable

Feed these into the standard restic chain; Meilisearch is derived data and can be
re-indexed rather than backed up.

## 7. Prod deltas (decided when prod happens)

- Confirm architecture with the senior first. Likely: PostgreSQL on its own host —
  that is only a `DATABASE_URL` change in `.env`; the supervisor programs already use
  `autorestart` rather than init-order dependencies, so they survive a remote DB.
- ZFS on the host; Proxmox snapshots stay the pre-upgrade gate either way.
- Size `/var/data/open-archiver` for real mail volume; FAFO's 30 GB is not a prod number.
- Consider Tika (adds a JVM) if attachment-format coverage in search proves too narrow —
  see `BARE-METAL-PLAN.md` §4.
- Prod sits behind a FortiGate — skip the host firewall with
  `install.sh --no-firewall` and let the FortiGate policy expose 80/443 only.
  (nftables stays on for FAFO, where the host has a directly-routed global IPv6 address.)
