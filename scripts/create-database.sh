#!/usr/bin/env bash
# Creates a database on the target Postgres when it is missing. The migrations create schemas and tables, never a database,
# so a service that keeps its tables in a database of its own (the Agent Web UI: agentwebui) needs this before `migrations/up`.
#
#   scripts/create-database.sh <database>        (make database/create DATABASE=<database>)
#
# The target is MIGRATIONS_DB_DSN (default: the shared cluster's Postgres, as for migrate). The script connects to the database
# `postgres` of that server, so the database name in the DSN is not used. Running it again changes nothing.
# How it reaches the server:
#   - PG_CONTAINER set: through `docker exec` in that container (the DSN's user, by the container's socket);
#   - otherwise psql, when it is on the PATH (it uses the DSN, password included);
#   - otherwise `docker exec` in yape-postgres, the cluster's Postgres, when the DSN is localhost:5432 (the port it publishes).
# The name is lower-case letters, digits and _ (it starts with a letter or _): it goes into the SQL as it is.
set -euo pipefail

die() { echo "Error: $*" >&2; exit 1; }

NAME="${1:-}"
[[ -n "${NAME}" ]] || die "usage: $0 <database>"
[[ "${NAME}" =~ ^[a-z_][a-z0-9_]{0,62}$ ]] || die "the database name '${NAME}' must be lower-case letters, digits and _, starting with a letter or _ (at most 63)"

DSN="${MIGRATIONS_DB_DSN:-postgres://postgres@localhost:5432/postgres?sslmode=disable}"
[[ "${DSN}" == postgres://* || "${DSN}" == postgresql://* ]] || die "MIGRATIONS_DB_DSN must be a postgres:// URL"
admin_dsn="$(sed -E 's#^([a-z]+://[^/]+)/[^?]*#\1/postgres#' <<< "${DSN}")"
user="$(sed -E 's#^[a-z]+://([^:@/]+).*#\1#' <<< "${DSN}")"
host="$(sed -E 's#^[a-z]+://([^@/]*@)?([^:/?]+).*#\2#' <<< "${DSN}")"
port="$(sed -nE 's#^[a-z]+://([^@/]*@)?[^:/?]+:([0-9]+).*#\2#p' <<< "${DSN}")"
port="${port:-5432}"

container="${PG_CONTAINER:-}"
if [[ -z "${container}" ]] && ! command -v psql >/dev/null 2>&1; then
  [[ ( "${host}" == localhost || "${host}" == 127.0.0.1 ) && "${port}" == 5432 ]] \
    || die "psql is not installed and ${host}:${port} is not the cluster's Postgres (localhost:5432): install psql, or set PG_CONTAINER"
  container="yape-postgres"
fi

sql() {
  if [[ -n "${container}" ]]; then
    command -v docker >/dev/null 2>&1 || die "docker not found (needed for PG_CONTAINER ${container})"
    docker exec -i "${container}" psql -U "${user}" -d postgres -v ON_ERROR_STOP=1 -qAt
  else
    psql "${admin_dsn}" -v ON_ERROR_STOP=1 -qAt
  fi
}

if [[ -n "$(sql <<< "SELECT 1 FROM pg_database WHERE datname = '${NAME}'")" ]]; then
  echo "The database ${NAME} already exists."
else
  sql <<< "CREATE DATABASE ${NAME}" >/dev/null
  echo "Created the database ${NAME}."
fi
