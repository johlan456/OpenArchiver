#!/bin/sh
# Open Archiver process launcher — invoked by supervisor.
# Sources the deployed .env (root pnpm scripts use dotenv-cli; supervisor
# cannot source env files, so this wrapper does) and execs the right process.
# Usage: oa-run.sh backend|frontend|ingestion-worker|indexing-worker|sync-scheduler
set -eu

APP_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
COMPONENT="${1:?usage: oa-run.sh <component>}"

cd "$APP_DIR"
[ -f .env ] || { echo "FATAL: $APP_DIR/.env not found" >&2; exit 1; }
set -a
. ./.env
set +a

case "$COMPONENT" in
	backend)
		exec node apps/open-archiver/dist/index.js
		;;
	frontend)
		# SvelteKit node adapter reads PORT/HOST, not PORT_FRONTEND.
		# Bind loopback only — Caddy is the sole public listener.
		PORT="${PORT_FRONTEND:-3000}" HOST=127.0.0.1 \
			exec node packages/frontend/build/index.js
		;;
	ingestion-worker)
		exec node packages/backend/dist/workers/ingestion.worker.js
		;;
	indexing-worker)
		exec node packages/backend/dist/workers/indexing.worker.js
		;;
	sync-scheduler)
		exec node packages/backend/dist/jobs/schedulers/sync-scheduler.js
		;;
	*)
		echo "FATAL: unknown component '$COMPONENT'" >&2
		exit 1
		;;
esac
