#!/usr/bin/env bash
# Checks that every migrations/<service>/<flow>/ folder is idempotent, on a
# throwaway Postgres in Docker. It never touches the cluster. For each folder, on a
# fresh database:
#   1. up, then up again: the schema (tables, columns, constraints, indexes,
#      comments) is identical after the second run, and nothing fails;
#   2. down twice: it succeeds both times and leaves no table of the folder;
#   3. up after down: the schema is identical to the first run.
# The SQL files are run directly with psql, so this tests the SQL and not migrate.
# Then, through scripts/migrate.sh: up twice (the second says "no change"), and up
# again after the version tables are dropped, which is what an existing database
# without them looks like (the tables stay, the schema must not change).
# Usage: scripts/check-migrations.sh      (needs Docker and the migrate CLI)
set -euo pipefail

ROOT="${MIGRATIONS_ROOT:-./migrations}"
IMAGE="${PG_IMAGE:-postgres:18-alpine}"
NAME="migrations-check-$$"
failures=0

command -v docker >/dev/null || { echo "Error: docker not found" >&2; exit 1; }
command -v "${MIGRATE:-migrate}" >/dev/null || { echo "Error: migrate not found. Run: make install" >&2; exit 1; }

docker run -d --rm --name "${NAME}" -e POSTGRES_PASSWORD=x -p 127.0.0.1::5432 "${IMAGE}" >/dev/null
trap 'docker rm -f "${NAME}" >/dev/null 2>&1 || true' EXIT

for _ in $(seq 1 60); do
  docker exec "${NAME}" pg_isready -U postgres -d postgres >/dev/null 2>&1 && break
  sleep 1
done
# The image restarts once while it initialises; wait until it answers a query.
for _ in $(seq 1 30); do
  docker exec "${NAME}" psql -U postgres -At -c 'select 1' >/dev/null 2>&1 && break
  sleep 1
done

psql_db() { docker exec -i "${NAME}" psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -q -At; }

# The schema as text, without the version tables or pg_dump's noise (its random
# \restrict token changes on every run).
dump_schema() {
  docker exec "${NAME}" pg_dump -U postgres -d "$1" --schema-only --no-owner --no-privileges \
    -T '*schema_migrations' | grep -v -e '^--' -e '^SET ' -e '^SELECT pg_catalog.set_config' -e '^\\restrict' -e '^\\unrestrict' -e '^$'
}

# Tables of every schema the migrations can create, not only public, so a folder that puts its
# tables in a schema of its own (history/camel_conversation) is checked too. The version tables
# stay in public and are left out.
tables_of() {
  psql_db "$1" <<< "select count(*) from information_schema.tables where table_schema not in ('pg_catalog', 'information_schema') and table_name not like '%schema_migrations'"
}

apply() { # database, files...
  local db="$1"; shift
  local f
  for f in "$@"; do psql_db "${db}" < "${f}" >/dev/null; done
}

fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
pass() { echo "ok    $*"; }

for dir in $(find "${ROOT}" -mindepth 2 -maxdepth 2 -type d | sort); do
  label="${dir#"${ROOT}"/}"
  db="chk_$(echo "${label}" | tr '/-' '__')"
  ups=(); downs=()
  while IFS= read -r f; do ups+=("${f}"); done < <(find "${dir}" -name '*.up.sql' | sort)
  while IFS= read -r f; do downs+=("${f}"); done < <(find "${dir}" -name '*.down.sql' | sort -r)
  [[ ${#ups[@]} -gt 0 && ${#ups[@]} -eq ${#downs[@]} ]] || { fail "${label}: up and down files do not pair"; continue; }

  docker exec "${NAME}" createdb -U postgres "${db}"

  if apply "${db}" "${ups[@]}" 2>/dev/null; then pass "${label}: up"; else fail "${label}: up"; continue; fi
  first="$(dump_schema "${db}")"
  [[ -n "${first}" ]] || { fail "${label}: up created nothing"; continue; }

  if apply "${db}" "${ups[@]}" 2>/dev/null; then pass "${label}: up again"; else fail "${label}: up again"; fi
  if [[ "$(dump_schema "${db}")" == "${first}" ]]; then pass "${label}: schema unchanged by the second up"; else fail "${label}: schema changed by the second up"; fi

  if apply "${db}" "${downs[@]}" 2>/dev/null && apply "${db}" "${downs[@]}" 2>/dev/null; then pass "${label}: down twice"; else fail "${label}: down twice"; fi
  if [[ "$(tables_of "${db}")" == "0" ]]; then pass "${label}: down leaves no table"; else fail "${label}: down leaves tables"; fi

  apply "${db}" "${ups[@]}" 2>/dev/null || fail "${label}: up after down"
  if [[ "$(dump_schema "${db}")" == "${first}" ]]; then pass "${label}: up after down gives the same schema"; else fail "${label}: up after down changed the schema"; fi
done

# Through migrate, all folders in one database, as on the cluster.
port="$(docker port "${NAME}" 5432/tcp | head -1 | sed 's/.*://')"
docker exec "${NAME}" createdb -U postgres chk_migrate
export MIGRATIONS_ROOT="${ROOT}"
export MIGRATIONS_DB_DSN="postgres://postgres:x@127.0.0.1:${port}/chk_migrate?sslmode=disable"

./scripts/migrate.sh all all up >/dev/null 2>&1 && pass "migrate: up" || fail "migrate: up"
all_first="$(dump_schema chk_migrate)"
# Nothing may be created in public but migrate's own version tables: every table and view lives in the schema of its folder.
if [[ "$(psql_db chk_migrate <<< "select count(*) from information_schema.tables where table_schema = 'public' and table_name not like '%schema_migrations'")" == "0" ]]; then
  pass "migrate: no table or view is created in public (only the version tables)"
else
  fail "migrate: something was created in public"
fi
for schema in event_store history camel_history dead_letter; do
  if [[ "$(psql_db chk_migrate <<< "select count(*) from information_schema.schemata where schema_name = '${schema}'")" == "1" ]]; then pass "migrate: schema ${schema} exists after up"; else fail "migrate: schema ${schema} is missing after up"; fi
done
second="$(./scripts/migrate.sh all all up 2>&1 || true)"
if [[ "$(grep -c 'no change' <<< "${second}")" -eq "$(find "${ROOT}" -mindepth 2 -maxdepth 2 -type d | wc -l | tr -d ' ')" ]]; then
  pass "migrate: second up says no change in every folder"
else
  fail "migrate: second up did not say no change everywhere"
fi

psql_db chk_migrate <<< "select 'drop table ' || quote_ident(table_name) || ';' from information_schema.tables where table_name like '%schema_migrations'" | psql_db chk_migrate
if ./scripts/migrate.sh all all up >/dev/null 2>&1; then pass "migrate: up over existing tables without version tables"; else fail "migrate: up over existing tables without version tables"; fi
if [[ "$(dump_schema chk_migrate)" == "${all_first}" ]]; then pass "migrate: schema unchanged by that up"; else fail "migrate: schema changed by that up"; fi

# The publication Debezium reads covers exactly the event store table, and the trigger that makes it append-only is there.
if [[ "$(psql_db chk_migrate <<< "select count(*) from pg_publication_tables where pubname = 'conversation_events' and schemaname = 'event_store' and tablename = 'conversation_events'")" == "1" ]]; then pass "migrate: the publication conversation_events covers event_store.conversation_events"; else fail "migrate: the publication does not cover event_store.conversation_events"; fi
if [[ "$(psql_db chk_migrate <<< "select count(*) from pg_publication_tables where pubname = 'conversation_events'")" == "1" ]]; then pass "migrate: the publication covers that table only"; else fail "migrate: the publication covers other tables"; fi
# The append-only trigger is a statement trigger, so it refuses an UPDATE even when the table has no row to change.
if psql_db chk_migrate <<< "update event_store.conversation_events set flow = 'x'" >/dev/null 2>&1; then fail "migrate: an UPDATE of the event store was accepted"; else pass "migrate: an UPDATE of the event store is refused (append-only)"; fi
# The shared dead-letter table: what a consumer relies on when it writes a refused record.
dl() { psql_db chk_migrate <<< "$1" 2>/dev/null; }
dl_ok() { if dl "$2" >/dev/null; then pass "dead_letter: $1"; else fail "dead_letter: $1"; fi; }
dl_refused() { if dl "$2" >/dev/null; then fail "dead_letter: $1 was accepted"; else pass "dead_letter: $1"; fi; }
dl_ok "a row with only what a consumer always knows is accepted" \
  "insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason) values ('svc-a', 'topic-1', 0, 10, 'json')"
if [[ "$(dl "select status || ',' || attempt || ',' || (resolved_at is null) from dead_letter.dead_letters where service = 'svc-a'")" == "open,1,true" ]]; then pass "dead_letter: a new row is open, on attempt 1, unresolved"; else fail "dead_letter: the defaults are wrong"; fi
dl_refused "the same source record twice for the same service" \
  "insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason) values ('svc-a', 'topic-1', 0, 10, 'json')"
if [[ "$(dl "with ins as (insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason) values ('svc-a', 'topic-1', 0, 10, 'json') on conflict do nothing returning 1) select count(*) from ins")" == "0" ]]; then pass "dead_letter: ON CONFLICT DO NOTHING makes a retried insert harmless"; else fail "dead_letter: a retried insert added a row"; fi
dl_ok "another service may dead-letter the same source record" \
  "insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason) values ('svc-b', 'topic-1', 0, 10, 'json')"
dl_refused "a negative offset" \
  "insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason) values ('svc-a', 'topic-1', 0, -1, 'json')"
dl_refused "a status outside open, replayed and discarded" \
  "insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason, status, resolved_at) values ('svc-a', 'topic-1', 0, 11, 'json', 'bogus', now())"
dl_refused "an open row that has a resolution time" \
  "insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason, resolved_at) values ('svc-a', 'topic-1', 0, 12, 'json', now())"
dl_refused "a replayed row with no resolution time" \
  "insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason, status) values ('svc-a', 'topic-1', 0, 13, 'json', 'replayed')"
dl_ok "a row is resolved by setting the status and the time together" \
  "update dead_letter.dead_letters set status = 'replayed', resolved_at = now(), resolution_note = 'republished' where service = 'svc-a' and source_offset = 10"
# The record is kept as bytes: a NUL, a byte that is not UTF-8 and a Schema Registry header must come back exactly as they went in.
dl_ok "a record with a NUL and bytes that are not UTF-8 is accepted" \
  "insert into dead_letter.dead_letters (service, source_topic, source_partition, source_offset, reason, record_key, record_value, headers, field, detail, exception_class, attempt, source_timestamp) values ('svc-a', 'topic-1', 1, 20, 'store-rejected', '\\x7b226b223a317d'::bytea, '\\x0000000002007bff0a80'::bytea, '{\"h\":\"v\"}', 'sqlstate-22021', 'the store refuses the data for good', null, 3, now())"
if [[ "$(dl "select encode(record_value, 'hex') || ',' || encode(record_key, 'hex') || ',' || (headers ->> 'h') from dead_letter.dead_letters where source_offset = 20")" == "0000000002007bff0a80,7b226b223a317d,v" ]]; then pass "dead_letter: key, value and headers come back byte for byte"; else fail "dead_letter: the record did not come back as it went in"; fi

# A database can record a version above the folder's latest migration (a migration
# that no longer exists was applied). up must reset it to the latest instead of
# stopping with "no migration found for version N", and must not touch the tables.
./scripts/migrate.sh all all up >/dev/null 2>&1
before_ahead="$(dump_schema chk_migrate)"
psql_db chk_migrate <<< "update history_camel_conversation_schema_migrations set version = 99"
if ./scripts/migrate.sh history camel_conversation up >/dev/null 2>&1; then pass "migrate: up with a recorded version above the latest migration"; else fail "migrate: up with a recorded version above the latest migration"; fi
latest_camel="$(find "${ROOT}/history/camel_conversation" -name '*.up.sql' | sed 's|.*/0*\([0-9][0-9]*\)_.*|\1|' | sort -n | tail -1)"
if [[ "$(psql_db chk_migrate <<< "select version from history_camel_conversation_schema_migrations")" == *"${latest_camel}"* ]]; then pass "migrate: the recorded version is reset to the latest migration"; else fail "migrate: the recorded version was not reset"; fi
if [[ "$(dump_schema chk_migrate)" == "${before_ahead}" ]]; then pass "migrate: the reset leaves the tables alone"; else fail "migrate: the reset changed the tables"; fi
psql_db chk_migrate <<< "update history_conversation_schema_migrations set version = 99, dirty = true"
if ./scripts/migrate.sh history conversation up >/dev/null 2>&1; then fail "migrate: a dirty version is not reset silently"; else pass "migrate: a dirty version is not reset silently"; fi
latest_history="$(find "${ROOT}/history/conversation" -name '*.up.sql' | sed 's|.*/0*\([0-9][0-9]*\)_.*|\1|' | sort -n | tail -1)"
psql_db chk_migrate <<< "update history_conversation_schema_migrations set version = ${latest_history}, dirty = false"

if ./scripts/migrate.sh all all down >/dev/null 2>&1 && [[ "$(tables_of chk_migrate)" == "0" ]]; then pass "migrate: down leaves no table"; else fail "migrate: down"; fi
if [[ "$(psql_db chk_migrate <<< "select (select count(*) from pg_publication) + (select count(*) from information_schema.schemata where schema_name in ('event_store', 'history', 'camel_history', 'dead_letter'))")" == "0" ]]; then pass "migrate: down also drops the publication and the four schemas"; else fail "migrate: down left the publication or a schema"; fi

echo
if [[ ${failures} -eq 0 ]]; then echo "All migration checks passed."; else echo "${failures} check(s) failed."; exit 1; fi
