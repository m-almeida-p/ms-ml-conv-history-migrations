#!/usr/bin/env bash
# Sets up the database of the Agent Web UI (iApe-UI): creates it when it is missing, applies migrations/web_ui/chat to it, and
# prints the DB_URL the web UI needs. Running it again changes nothing.
#
#   scripts/setup-web-ui.sh          (make web-ui/setup)
#
# The database is WEB_UI_DATABASE (default agentwebui) on the server MIGRATIONS_DB_DSN names (default: the shared cluster's
# Postgres, as for migrate); the database in that DSN is not used. create-database.sh does the first step, so PG_CONTAINER and
# the rest of what it reads apply here too.
set -euo pipefail

DB="${WEB_UI_DATABASE:-agentwebui}"
DSN="${MIGRATIONS_DB_DSN:-postgres://postgres@localhost:5432/postgres?sslmode=disable}"

./scripts/create-database.sh "${DB}"
web_dsn="$(sed -E "s#^([a-z]+://[^/]+)/[^?]*#\\1/${DB}#" <<< "${DSN}")"
MIGRATIONS_DB_DSN="${web_dsn}" ./scripts/migrate.sh web_ui chat up

# The URL for the web UI: no password (set it where the web UI keeps its settings), and the schema its tables are in.
db_url="$(sed -E 's#(://[^:/@]+):[^@/]+@#\1@#' <<< "${web_dsn}")"
[[ "${db_url}" == *\?* ]] && db_url="${db_url}&search_path=web_ui" || db_url="${db_url}?search_path=web_ui"
echo
echo "The Agent Web UI's database is ready. In its settings:"
echo "  DB_URL=\"${db_url}\""
