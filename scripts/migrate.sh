#!/usr/bin/env bash
# Runs golang-migrate for the migrations of one service and flow, or for several.
#
#   scripts/migrate.sh <service|all> <flow|all> <up|down|version|goto N|force N|new NAME>
#
# Layout: migrations/<service>/<flow>/, for example migrations/history/conversation. A new
# flow is a new folder; nothing here lists the flows. Each folder numbers its files
# from 000001, so each keeps its applied version in its own table,
# <service>_<flow>_schema_migrations, and the folders evolve apart in one database.
#
# `all` is allowed for up, down and version. Down runs backwards: the services and the
# flows of a service in reverse order. goto, force and new need one
# service and one flow.
# Settings come from the environment (the Makefile passes them):
#   MIGRATIONS_ROOT, MIGRATIONS_DB_DSN, MIGRATE
set -euo pipefail

ROOT="${MIGRATIONS_ROOT:-./migrations}"
DSN="${MIGRATIONS_DB_DSN:-postgres://postgres@localhost:5432/postgres?sslmode=disable}"
MIGRATE="${MIGRATE:-migrate}"

# One entry per owning service, in the order its folders must be applied.
SERVICES=(history)

die() { echo "Error: $*" >&2; exit 1; }

table_of() { echo "${1}_${2//-/_}_schema_migrations"; }

dsn_for() {
  local separator="?"
  [[ "${DSN}" == *\?* ]] && separator="&"
  echo "${DSN}${separator}x-migrations-table=$(table_of "$1" "$2")"
}

run() {
  local service="$1" flow="$2"; shift 2
  "${MIGRATE}" -path="${ROOT}/${service}/${flow}" -database="$(dsn_for "${service}" "${flow}")" "$@"
}

# Prints "service flow" lines for what the selection matches, in run order.
pairs() {
  local service flow
  for service in "${SERVICES[@]}"; do
    [[ "$1" == "all" || "$1" == "${service}" ]] || continue
    [[ -d "${ROOT}/${service}" ]] || continue
    for flow in $(find "${ROOT}/${service}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort); do
      [[ "$2" == "all" || "$2" == "${flow}" ]] || continue
      echo "${service} ${flow}"
    done
  done
}

# The highest migration number in a folder (0 when it has none).
latest_of() {
  find "${ROOT}/$1/$2" -maxdepth 1 -name '*.up.sql' | sed 's|.*/\([0-9][0-9]*\)_.*|\1|' | sort -n | tail -1 | sed 's/^0*//' | grep . || echo 0
}

# A database can record a version above the folder's latest migration: a migration
# that no longer exists was applied. migrate then stops with "no migration found for
# version N". Reset the record to the latest migration that exists so up goes on. The
# tables are not touched, and a dirty record (a migration that failed half way) is left
# alone, because only a person can say what state it left.
align_version() {
  local service="$1" flow="$2" recorded latest
  recorded="$(run "${service}" "${flow}" version 2>&1 | head -1 || true)"
  [[ "${recorded}" =~ ^([0-9]+)$ ]] || return 0
  recorded="${BASH_REMATCH[1]}"
  latest="$(latest_of "${service}" "${flow}")"
  if (( recorded > latest )); then
    echo "recorded version ${recorded} is above the latest migration ${latest}; resetting the record to ${latest}"
    run "${service}" "${flow}" force "${latest}"
  fi
}

[[ $# -ge 3 ]] || die "usage: $0 <service|all> <flow|all> <command> [args]"
service="$1"; flow="$2"; command="$3"; shift 3

command -v "${MIGRATE}" >/dev/null || die "'${MIGRATE}' not found. Run: make install"
[[ "${service}" == "all" || " ${SERVICES[*]} " == *" ${service} "* ]] || die "unknown service '${service}' (use ${SERVICES[*]} or all)"

selected=()
while IFS= read -r line; do selected+=("${line}"); done < <(pairs "${service}" "${flow}")
[[ ${#selected[@]} -gt 0 ]] || die "no folder under ${ROOT} for service=${service} flow=${flow}"

case "${command}" in
  up | version)
    for line in "${selected[@]}"; do
      echo "== ${line% *}/${line#* } =="
      [[ "${command}" == "up" ]] && align_version ${line}
      run ${line} "${command}" "$@"
    done
    ;;
  down)
    for ((i = ${#selected[@]} - 1; i >= 0; i--)); do
      echo "== ${selected[i]% *}/${selected[i]#* } =="
      run ${selected[i]} down -all
    done
    ;;
  goto | force | new)
    [[ ${#selected[@]} -eq 1 && "${service}" != "all" && "${flow}" != "all" ]] \
      || die "'${command}' needs one service and one flow: SERVICE=<service> FLOW=<flow>"
    if [[ "${command}" == "new" ]]; then
      [[ $# -ge 1 ]] || die "usage: $0 ${service} ${flow} new <snake_case_name>"
      "${MIGRATE}" create -ext sql -dir "${ROOT}/${service}/${flow}" -seq "$1"
    else
      run ${selected[0]} "${command}" "$@"
    fi
    ;;
  *) die "unknown command '${command}'" ;;
esac
