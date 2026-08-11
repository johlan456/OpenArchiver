#!/usr/bin/env bash
# Open Archiver upgrade — run ON the host, as root, from inside the repo:
#   sudo ./deploy/upgrade.sh [git-ref]      (default: origin/main)
#
# Flow: pg_dump → hypervisor-snapshot gate → fetch → env-drift check →
# fast-forward merge → build → migrate (forward-only!) → restart → health check.
#
# The desktop-side flow is: merge the upstream tag into main there, push to
# origin; this script only ever fast-forwards to what was pushed.
set -euo pipefail

APP_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APP_USER="openarchiver"
APP_HOME="$APP_DIR"   # app user home = app dir (/srv convention)
BACKUP_DIR="/var/backups/openarchiver"
REF="origin/main"
ASSUME_YES=0
FORCE_ENV=0
DRY_RUN=0

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }
as_app() { sudo -u "$APP_USER" env HOME="$APP_HOME" PATH="/usr/local/bin:$PATH" sh -c "cd '$APP_DIR' && $*"; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--yes|-y) ASSUME_YES=1; shift ;;
		--force-env) FORCE_ENV=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-*) die "unknown flag: $1" ;;
		*) REF="$1"; shift ;;
	esac
done

[[ $EUID -eq 0 || $DRY_RUN -eq 1 ]] || die "must run as root (sudo)"
[[ -f "$APP_DIR/.env" ]] || die "no deployed .env at $APP_DIR — run install.sh first"

log "Upgrading to: $REF"
as_app "git fetch origin --tags --prune"
NEW_COMMIT=$(as_app "git rev-parse --verify '$REF^{commit}'") || die "unknown ref: $REF"
CUR_COMMIT=$(as_app "git rev-parse HEAD")
if [[ "$NEW_COMMIT" == "$CUR_COMMIT" ]]; then
	log "Already at $REF ($CUR_COMMIT) — nothing to do"
	exit 0
fi
as_app "git merge-base --is-ancestor HEAD '$NEW_COMMIT'" \
	|| die "$REF is not a fast-forward from HEAD — the additive-only rule was broken somewhere; resolve on the desktop, not here"

# ---- env drift check: new keys in .env.example must be handled ----
log "Checking .env.example for new keys"
NEW_KEYS=$(as_app "git show '$NEW_COMMIT:.env.example'" | grep -oE '^[A-Z_0-9]+=' | tr -d '=' | sort -u)
DEPLOYED_KEYS=$(grep -oE '^[A-Z_0-9]+=' "$APP_DIR/.env" | tr -d '=' | sort -u)
MISSING=$(comm -23 <(echo "$NEW_KEYS") <(echo "$DEPLOYED_KEYS") || true)
if [[ -n "$MISSING" ]]; then
	warn "keys in the new .env.example that are NOT in the deployed .env:"
	printf '    %s\n' $MISSING >&2
	if [[ $FORCE_ENV -eq 0 ]]; then
		die "handle these in $APP_DIR/.env (or check upstream defaults are OK and re-run with --force-env)"
	fi
	warn "--force-env given, continuing with upstream defaults for the above"
fi

if [[ $DRY_RUN -eq 1 ]]; then
	log "[dry-run] would: pg_dump, merge $CUR_COMMIT..$NEW_COMMIT, build, migrate, restart"
	exit 0
fi

# ---- backups: pg_dump is mandatory; hypervisor snapshot is gated on the operator ----
log "Dumping database to $BACKUP_DIR"
install -d -o postgres -g postgres -m 750 "$BACKUP_DIR"
DUMP_FILE="$BACKUP_DIR/open_archive-$(date +%Y%m%d-%H%M%S)-pre-$(echo "$NEW_COMMIT" | cut -c1-8).dump"
sudo -u postgres pg_dump -Fc -f "$DUMP_FILE" open_archive
log "Dump written: $DUMP_FILE"

if [[ $ASSUME_YES -eq 0 ]]; then
	echo
	echo "  *** Take a hypervisor (Proxmox) snapshot of this VM NOW. ***"
	echo "  Migrations are forward-only; the snapshot is the rollback path."
	echo
	read -r -p "Snapshot taken — continue? [y/N] " answer
	[[ "$answer" =~ ^[Yy]$ ]] || die "aborted by operator"
fi

log "Fast-forwarding $CUR_COMMIT → $NEW_COMMIT"
as_app "git merge --ff-only '$NEW_COMMIT'"

log "Installing dependencies + building"
as_app "pnpm install --shamefully-hoist --frozen-lockfile --prod=false"
as_app "pnpm build:oss"

log "Running migrations (forward-only)"
as_app "pnpm db:migrate"

log "Restarting application"
supervisorctl restart 'openarchiver:*'

log "Health check (waiting 15s)"
sleep 15
supervisorctl status 'openarchiver:*' || true
FAILURES=0
for check in "frontend:http://127.0.0.1:3000/" "backend:http://127.0.0.1:4000/"; do
	name="${check%%:*}"; url="${check#*:}"
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null) || code="000"
	if [[ $code == 000 ]]; then
		warn "$name not responding at $url"
		FAILURES=$((FAILURES + 1))
	else
		log "$name responding (HTTP $code)"
	fi
done
if [[ $FAILURES -gt 0 ]]; then
	warn "upgrade is UNHEALTHY. Rollback: restore the Proxmox snapshot (preferred),"
	warn "or: git reset --hard $CUR_COMMIT && rebuild, then pg_restore -d open_archive $DUMP_FILE"
	exit 1
fi
log "Upgrade to $REF complete and healthy."
