#!/usr/bin/env bash
# Open Archiver bare-metal installer — Devuan/Debian, sysvinit + supervisor.
#
# Run ON the target host, as root, from inside the cloned repo:
#   sudo ./deploy/install.sh --domain archive.example.com
#
# What it does (see deploy/DEPLOY.md for the full runbook):
#   apt deps → Node 22 + pnpm → users/dirs → Caddy + Meilisearch binaries
#   → PostgreSQL role/db → Valkey auth → render .env (secrets generated here,
#   never committed) → firewall → build → migrate → supervisor programs → health check.
#
# Idempotent: safe to re-run. Existing .env and DB credentials are preserved.
set -euo pipefail

# ---------- configuration ----------
APP_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="$APP_DIR/deploy"
APP_USER="openarchiver"
APP_HOME="$APP_DIR"   # app user home = app dir (/srv convention)
DATA_DIR="/var/data/open-archiver"
LOG_DIR="/var/log/openarchiver"
PNPM_VERSION="10.13.1"          # pinned in root package.json engines
NODE_MAJOR="22"
MEILI_VERSION="${MEILI_VERSION:-v1.38.0}"   # docker-compose pins image v1.38
DOMAIN=""
DRY_RUN=0
SKIP_FIREWALL=0

# ---------- helpers ----------
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }
run() {
	if [[ $DRY_RUN -eq 1 ]]; then
		printf '\033[0;36m[dry-run]\033[0m %s\n' "$*"
	else
		"$@"
	fi
}

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
	echo "Options:"
	echo "  --domain <fqdn>   public domain (required unless .env already exists)"
	echo "  --dry-run         print actions without executing"
	echo "  --no-firewall     skip the nftables ruleset (host is behind an upstream firewall)"
	exit "${1:-0}"
}

# ---------- args ----------
while [[ $# -gt 0 ]]; do
	case "$1" in
		--domain) DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
		--domain=*) DOMAIN="${1#*=}"; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		--no-firewall) SKIP_FIREWALL=1; shift ;;
		-h|--help) usage 0 ;;
		*) die "unknown argument: $1 (see --help)" ;;
	esac
done

# ---------- preflight ----------
preflight() {
	log "Preflight"
	[[ $EUID -eq 0 || $DRY_RUN -eq 1 ]] || die "must run as root (sudo)"
	[[ -f "$APP_DIR/package.json" ]] || die "repo not found at $APP_DIR — clone it first"
	grep -q 'open-archiver' "$APP_DIR/package.json" || die "$APP_DIR does not look like the OpenArchiver repo"
	[[ -f /etc/os-release ]] && . /etc/os-release
	case "${ID:-}${ID_LIKE:-}" in
		*devuan*|*debian*) : ;;
		*) warn "untested distro '${ID:-unknown}' — expecting Devuan/Debian" ;;
	esac
	if [[ ! -f "$APP_DIR/.env" && -z "$DOMAIN" ]]; then
		die "--domain is required for first install (no existing .env)"
	fi
	command -v supervisord >/dev/null 2>&1 || log "supervisor will be installed"
}

# ---------- steps ----------
install_apt_packages() {
	log "Installing apt packages"
	run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
		postgresql valkey-server supervisor nftables \
		git curl ca-certificates xz-utils openssl
}

install_node() {
	if command -v node >/dev/null 2>&1 && node -v | grep -q "^v${NODE_MAJOR}\."; then
		log "Node $(node -v) already installed"
	else
		log "Installing Node ${NODE_MAJOR}.x from nodejs.org"
		local tarball
		tarball=$(curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/" \
			| grep -o "node-v${NODE_MAJOR}\.[0-9.]*-linux-x64\.tar\.xz" | head -1)
		[[ -n $tarball ]] || die "could not determine latest Node ${NODE_MAJOR}.x tarball"
		local ver="${tarball%-linux-x64.tar.xz}"
		run mkdir -p /usr/local/lib/nodejs
		if [[ $DRY_RUN -eq 0 ]]; then
			curl -fsSL "https://nodejs.org/dist/latest-v${NODE_MAJOR}.x/${tarball}" \
				-o "/tmp/${tarball}"
			tar -xJf "/tmp/${tarball}" -C /usr/local/lib/nodejs
			rm -f "/tmp/${tarball}"
			ln -sf "/usr/local/lib/nodejs/${ver}-linux-x64/bin/node" /usr/local/bin/node
			ln -sf "/usr/local/lib/nodejs/${ver}-linux-x64/bin/npm" /usr/local/bin/npm
			ln -sf "/usr/local/lib/nodejs/${ver}-linux-x64/bin/npx" /usr/local/bin/npx
		else
			run echo "would install $tarball to /usr/local/lib/nodejs"
		fi
	fi
	if command -v pnpm >/dev/null 2>&1 && [[ "$(pnpm --version 2>/dev/null)" == "$PNPM_VERSION" ]]; then
		log "pnpm $PNPM_VERSION already installed"
	else
		log "Installing pnpm $PNPM_VERSION"
		run /usr/local/bin/npm install -g "pnpm@${PNPM_VERSION}"
	fi
}

create_users_and_dirs() {
	log "Creating service users and directories"
	id -u "$APP_USER" >/dev/null 2>&1 \
		|| run useradd --system --home-dir "$APP_HOME" --create-home --shell /usr/sbin/nologin "$APP_USER"
	id -u meilisearch >/dev/null 2>&1 \
		|| run useradd --system --home-dir /var/lib/meilisearch --create-home --shell /usr/sbin/nologin meilisearch
	run install -d -o "$APP_USER" -g "$APP_USER" -m 750 "$DATA_DIR"
	run install -d -m 755 "$LOG_DIR"
	run install -d -o www-data -g www-data -m 750 /etc/caddy/ssl /var/log/caddy
	run chown -R "$APP_USER:$APP_USER" "$APP_DIR"
}

install_caddy() {
	if [[ -x /usr/local/bin/caddy ]]; then
		log "Caddy already installed: $(/usr/local/bin/caddy version | head -1)"
	else
		log "Installing Caddy static binary"
		run curl -fsSL -o /usr/local/bin/caddy "https://caddyserver.com/api/download?os=linux&arch=amd64"
		run chmod 755 /usr/local/bin/caddy
	fi
	# www-data must bind :80/:443
	run setcap cap_net_bind_service=+ep /usr/local/bin/caddy
}

install_meilisearch() {
	if [[ -x /usr/local/bin/meilisearch ]]; then
		log "Meilisearch already installed: $(/usr/local/bin/meilisearch --version 2>/dev/null | head -1)"
		return
	fi
	log "Installing Meilisearch ${MEILI_VERSION}"
	run curl -fsSL -o /usr/local/bin/meilisearch \
		"https://github.com/meilisearch/meilisearch/releases/download/${MEILI_VERSION}/meilisearch-linux-amd64"
	run chmod 755 /usr/local/bin/meilisearch
}

# Secrets: generated once, then read back from the existing .env on re-runs.
read_env_var() { sed -n "s/^$1=[\"']\{0,1\}\([^\"']*\).*/\1/p" "$APP_DIR/.env" | head -1; }

render_env() {
	if [[ -f "$APP_DIR/.env" ]]; then
		log "Existing .env found — keeping it (secrets preserved)"
		PG_PASSWORD="$(read_env_var POSTGRES_PASSWORD)"
		REDIS_PASSWORD="$(read_env_var REDIS_PASSWORD)"
		MEILI_KEY="$(read_env_var MEILI_MASTER_KEY)"
		[[ -n $PG_PASSWORD && -n $REDIS_PASSWORD && -n $MEILI_KEY ]] \
			|| die "existing .env is missing POSTGRES_PASSWORD/REDIS_PASSWORD/MEILI_MASTER_KEY"
		return
	fi
	log "Rendering .env from deploy/env.template (generating secrets)"
	PG_PASSWORD="$(openssl rand -hex 24)"
	REDIS_PASSWORD="$(openssl rand -hex 24)"
	MEILI_KEY="$(openssl rand -hex 24)"
	local jwt enc storage_enc
	jwt="$(openssl rand -hex 48)"
	enc="$(openssl rand -hex 32)"
	storage_enc="$(openssl rand -hex 32)"
	if [[ $DRY_RUN -eq 1 ]]; then
		run echo "would render $APP_DIR/.env for domain $DOMAIN"
		return
	fi
	sed -e "s/@@ARCHIVE_DOMAIN@@/${DOMAIN}/g" \
		-e "s/@@POSTGRES_PASSWORD@@/${PG_PASSWORD}/g" \
		-e "s/@@REDIS_PASSWORD@@/${REDIS_PASSWORD}/g" \
		-e "s/@@MEILI_MASTER_KEY@@/${MEILI_KEY}/g" \
		-e "s/@@JWT_SECRET@@/${jwt}/g" \
		-e "s/@@ENCRYPTION_KEY@@/${enc}/g" \
		-e "s/@@STORAGE_ENCRYPTION_KEY@@/${storage_enc}/g" \
		"$DEPLOY_DIR/env.template" > "$APP_DIR/.env"
	chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
	chmod 600 "$APP_DIR/.env"
	# hard rule from the plan: ORIGIN must equal APP_URL
	local app_url origin
	app_url="$(read_env_var APP_URL)"; origin="$(read_env_var ORIGIN)"
	[[ "$app_url" == "$origin" ]] || die "ORIGIN ($origin) != APP_URL ($app_url) — refusing to continue"
}

setup_postgres() {
	log "Configuring PostgreSQL role + database"
	if [[ $DRY_RUN -eq 1 ]]; then run echo "would create role/db in postgres"; return; fi
	service postgresql start 2>/dev/null || true
	if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${APP_USER}'" | grep -q 1; then
		sudo -u postgres psql -v ON_ERROR_STOP=1 \
			-c "CREATE ROLE ${APP_USER} LOGIN PASSWORD '${PG_PASSWORD}'"
	else
		sudo -u postgres psql -v ON_ERROR_STOP=1 \
			-c "ALTER ROLE ${APP_USER} PASSWORD '${PG_PASSWORD}'"
	fi
	if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='open_archive'" | grep -q 1; then
		sudo -u postgres createdb -O "$APP_USER" open_archive
	fi
}

setup_valkey() {
	log "Configuring Valkey (requirepass, loopback bind)"
	local conf=/etc/valkey/valkey.conf
	if [[ $DRY_RUN -eq 1 ]]; then run echo "would set requirepass in $conf"; return; fi
	[[ -f $conf ]] || die "$conf not found — is valkey-server installed?"
	if grep -q '^requirepass ' "$conf"; then
		sed -i "s|^requirepass .*|requirepass ${REDIS_PASSWORD}|" "$conf"
	else
		printf '\nrequirepass %s\n' "$REDIS_PASSWORD" >> "$conf"
	fi
	grep -Eq '^bind .*(127\.0\.0\.1|localhost)' "$conf" || warn "valkey bind is not loopback — check $conf"
	service valkey-server restart
}

setup_firewall() {
	if [[ $SKIP_FIREWALL -eq 1 ]]; then
		log "Skipping host firewall (--no-firewall; upstream firewall must expose 80/443 only)"
		return
	fi
	log "Installing nftables ruleset (inbound: 22/80/443 + ICMP only)"
	run install -m 644 "$DEPLOY_DIR/nftables.conf" /etc/nftables.conf
	if [[ $DRY_RUN -eq 0 ]]; then
		nft -c -f /etc/nftables.conf || die "nftables ruleset failed validation"
		nft -f /etc/nftables.conf
	fi
	if [[ -x /etc/init.d/nftables ]]; then
		run update-rc.d nftables enable
	else
		# Devuan's nftables package ships no init script — persist via ifupdown hook
		log "No nftables init script — installing /etc/network/if-pre-up.d/nftables hook"
		if [[ $DRY_RUN -eq 0 ]]; then
			printf '#!/bin/sh\n# load host firewall before interfaces come up (installed by OpenArchiver deploy)\n[ "$IFACE" = lo ] || exit 0\nexec /usr/sbin/nft -f /etc/nftables.conf\n' \
				> /etc/network/if-pre-up.d/nftables
			chmod 755 /etc/network/if-pre-up.d/nftables
		fi
	fi
}

build_app() {
	log "Installing dependencies + building (as $APP_USER)"
	run sudo -u "$APP_USER" env HOME="$APP_HOME" PATH="/usr/local/bin:$PATH" \
		sh -c "cd '$APP_DIR' && pnpm install --shamefully-hoist --frozen-lockfile --prod=false"
	run sudo -u "$APP_USER" env HOME="$APP_HOME" PATH="/usr/local/bin:$PATH" \
		sh -c "cd '$APP_DIR' && pnpm build:oss"
}

run_migrations() {
	log "Running database migrations"
	run sudo -u "$APP_USER" env HOME="$APP_HOME" PATH="/usr/local/bin:$PATH" \
		sh -c "cd '$APP_DIR' && pnpm db:migrate"
}

install_supervisor_programs() {
	log "Installing supervisor programs + Caddy config"
	run install -m 644 "$DEPLOY_DIR/supervisor/openarchiver.conf" /etc/supervisor/conf.d/openarchiver.conf
	run install -m 644 "$DEPLOY_DIR/supervisor/caddy.conf" /etc/supervisor/conf.d/caddy.conf
	if [[ $DRY_RUN -eq 0 ]]; then
		sed "s/@@MEILI_MASTER_KEY@@/${MEILI_KEY}/g" \
			"$DEPLOY_DIR/supervisor/meilisearch.conf.template" > /etc/supervisor/conf.d/meilisearch.conf
		chmod 600 /etc/supervisor/conf.d/meilisearch.conf
		local domain
		domain="${DOMAIN:-$(read_env_var APP_URL | sed 's|https\?://||')}"
		sed "s/@@ARCHIVE_DOMAIN@@/${domain}/g" \
			"$DEPLOY_DIR/caddy/Caddyfile.template" > /etc/caddy/Caddyfile
		printf 'XDG_DATA_HOME=/etc/caddy/ssl\nUSER=www-data\n' > /etc/caddy/CaddyEnv
		/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --envfile /etc/caddy/CaddyEnv \
			|| die "Caddyfile failed validation"
	else
		run echo "would render meilisearch.conf + Caddyfile + CaddyEnv"
	fi
	run chmod +x "$DEPLOY_DIR/bin/oa-run.sh"
	run service supervisor start
	run supervisorctl reread
	run supervisorctl update
}

health_check() {
	[[ $DRY_RUN -eq 1 ]] && return
	log "Health check (waiting 15s for processes to settle)"
	sleep 15
	supervisorctl status || true
	local failures=0
	for check in "frontend:http://127.0.0.1:3000/" "backend:http://127.0.0.1:4000/" "meilisearch:http://127.0.0.1:7700/health"; do
		local name="${check%%:*}" url="${check#*:}"
		local code
		code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo 000)
		if [[ $code == 000 ]]; then
			warn "$name not responding at $url"
			failures=$((failures + 1))
		else
			log "$name responding (HTTP $code)"
		fi
	done
	if [[ $failures -gt 0 ]]; then
		die "$failures service(s) unhealthy — check $LOG_DIR/*.log"
	fi
	log "All services healthy. Public URL: $(read_env_var APP_URL)"
}

# ---------- main ----------
preflight
[[ $DRY_RUN -eq 0 ]] && apt-get update -qq
install_apt_packages
install_node
create_users_and_dirs
install_caddy
install_meilisearch
render_env
setup_postgres
setup_valkey
setup_firewall
build_app
run_migrations
install_supervisor_programs
health_check
log "Install complete."
