# ms-ml-conv-history-migrations

The database migrations of the conversation pipeline: the agent's event store, the publication Debezium reads, and the history tables built
from it; and the tables of `iApe-UI`, which does not create its own. The SQL here is the definition of the schemas: the services that use the tables (`ms-ml-genai-agents-bs`,
`ms-ml-conv-history-bs`, `ms-ml-camel-conv-history-bs`, `ms-ml-conv-history-consumer`) do not create them. They are applied with
[golang-migrate](https://github.com/golang-migrate/migrate).

## Where these came from

They were copied from `ml-genai-agents-bs-testing` (`migrations/agent/` and `migrations/history/`). The migrations of that repo are now
duplicates of these: delete them there when this repo is the one in use, so there is one place for them. The runner (`Makefile`,
`scripts/`) is the same one.

**Two changes from the copy. Nothing lives in `public` any more:** each folder now starts with a `000001_create_schema` migration, and every
later migration qualifies its names with that schema (the originals created their tables in `public`). The tables, columns, indexes and
the view are otherwise the same SQL. **And the publication Debezium reads is defined here** (it used to be created by the connector). Because the numbering and the location changed, **these migrations must be applied to a database
that does not have the old tables**: see [An existing database](#an-existing-database).

Nothing was removed from the source repo. The history folders there are now duplicates: delete them there when this repo is the one the
services use, so there is one place for them.

## Layout

`migrations/<service>/<flow>/`: one folder per owning service and per set of tables. A new set of tables is a new folder; nothing else
lists the folders. Every folder numbers its files from `000001` and records its applied version in `<service>_<flow>_schema_migrations`,
so the folders evolve apart in the same database.

| Folder | Schema | Objects | Used by | Version table |
|---|---|---|---|---|
| `migrations/agent/conversation/` | `event_store` | `conversation_events` (the append-only log) with its two indexes and its trigger, and the publication `conversation_events` | `ms-ml-genai-agents-bs` (writes it), Debezium (reads it) | `agent_conversation_schema_migrations` |
| `migrations/history/conversation/` | `history` | `conversation_inbox`, `conversation_messages`, `conversation_summaries`, the view `conversation_flow_segments` | `ms-ml-conv-history-bs` (the Go service) | `history_conversation_schema_migrations` |
| `migrations/history/camel_conversation/` | `camel_history` | the same three tables, and the two maps to Microsoft Foundry (`foundry_conversation_map`, `foundry_item_map`) | `ms-ml-camel-conv-history-bs` | `history_camel_conversation_schema_migrations` |
| `migrations/shared/dead_letter/` | `dead_letter` | `dead_letters`: the records every consumer refused for good, kept as received | every consumer (see [Dead letters](#dead-letters)) | `shared_dead_letter_schema_migrations` |
| `migrations/web_ui/chat/` | `web_ui` | `users`, `sessions`, `conversations`, `messages`: who signs in to iApe-UI and the chats they keep | `iApe-UI` (it connects with `search_path=web_ui`) | `web_ui_chat_schema_migrations` |

The tables have the same names in both schemas: the schema tells them apart (`history.conversation_inbox`,
`camel_history.conversation_inbox`), so no table name carries a prefix. Each folder's first migration creates its schema, and `down`
drops it last (without `CASCADE`, so it fails instead of deleting anything that was put in it).

**The version tables stay in `public`.** `migrate` creates them before it runs the first migration, when the folder's schema does not
exist yet, so they cannot live in it. They are the only objects in `public`; `make migrations/test` checks that nothing else is.

## Debezium

The connector `conversation-events` reads `event_store.conversation_events` through the publication `conversation_events` (migration
`000004`) and a replication slot of the same name. **The slot is not a migration**: it belongs to the connector, which creates it and
should drop it. These are the connector settings that go with these migrations:

| Setting | Value |
|---|---|
| `table.include.list` | `event_store.conversation_events` |
| `message.key.columns` | `event_store.conversation_events:conversation_id` |
| `publication.name` | `conversation_events` |
| `publication.autocreate.mode` | `disabled` (the publication comes from the migration, so the connector must not create its own) |
| `slot.name` | `conversation_events` |
| `topic.prefix` | `yape` |

**The topic name follows the schema**: it is `<topic.prefix>.<schema>.<table>`, so it becomes **`yape.event_store.conversation_events`**
(it was `yape.public.conversation_events`). A new topic is a new Schema Registry subject with a new schema id, so every consumer needs
the new `app.topic` and the new id in its allowed ids. The producer service must also write to `event_store.conversation_events` (the schema
in its connection settings, or in its SQL).

## An existing database

These migrations are meant for a database that has none of the old objects. **The local cluster was recreated from zero** (`clean.sh` in the
`cluster` repo) and the migrations were applied from version 1: all folders were applied (`agent/conversation` at 4,
`history/camel_conversation` at 5, `history/conversation` at 4), and nothing but the version tables is in `public`.

A database that still has the **old layout** (the tables and the view in `public`, `public.conversation_events` with its trigger, the publication and
slot `conversation_events`, the old connector, and the old version tables) cannot take them: `up` would not create the new schemas, because the
version tables say the work is done, and it would fail to create the publication, which already exists. Move it in this order: stop and delete
the old connector, drop its slot, the old publication, `public.conversation_events` and the old tables and version tables, then
`make migrations/up`, then register the connector with the settings above.

## Dead letters

`dead_letter.dead_letters` is where a consumer puts a record it **refused for good**, instead of a line in a log. No service owns it, so
the folder is `shared/`. It holds one row per source record and service.

| Column | What it is |
|---|---|
| `service`, `source_topic`, `source_partition`, `source_offset` | Who dead-lettered it and where the record is in Kafka. **Unique together**, so a retried insert changes nothing |
| `record_key`, `record_value`, `headers` | The record exactly as Kafka delivered it, as `bytea` (a NUL or a byte that is not UTF-8 is often why it was refused, and a replay must publish the same bytes) |
| `reason`, `field`, `detail`, `exception_class`, `attempt` | Why, in the consumer's own words (`schema-violation`, `store-rejected` with `sqlstate-22021`, `unexpected`, ...) and how many tries it took. `reason` is an open list: a new consumer may add its own |
| `status`, `failed_at`, `resolved_at`, `resolution_note` | `open`, `replayed` or `discarded`. A row is resolved exactly when it is not open, and the database enforces that |

**What goes in, and what does not.** Poison records (they break the contract, cannot be decoded, or the store refuses the data) and
unexpected errors that were retried and still failed. A failure that is not the record's fault (the database or the registry is down) is
retried in place and never lands here.

**How a consumer writes it.** In the dead-letter route, in the same step that today writes the log line, then commits the offset (the
Kamelet does that when the route returns):

```sql
INSERT INTO dead_letter.dead_letters
    (service, source_topic, source_partition, source_offset, source_timestamp, record_key, record_value, headers,
     reason, field, detail, exception_class, attempt)
VALUES (:service, :topic, :partition, :offset, :timestamp, :key, :value, :headers::jsonb,
        :reason, :field, :detail, :exceptionClass, :attempt)
ON CONFLICT (service, source_topic, source_partition, source_offset) DO NOTHING;
```

If the insert fails, the route throws and the record is read again, so a record is never lost. `ON CONFLICT DO NOTHING` makes the retry
harmless. The consumer's decoder must keep the **original bytes** of the key and the value (today it keeps text), or a replay cannot be exact.

**What is still to do.** This repo defines and tests the table, and it is applied to the local cluster. **No consumer writes to it yet**: their dead-letter route still writes a log line.

**Replay.** Read the open rows of one service, publish `record_key` and `record_value` to `source_topic`, then mark them:

```sql
SELECT id, source_topic, record_key, record_value FROM dead_letter.dead_letters
WHERE service = 'ms-ml-conv-history-consumer' AND status = 'open' ORDER BY failed_at;

UPDATE dead_letter.dead_letters
SET status = 'replayed', resolved_at = now(), resolution_note = 'fixed in the decoder, republished'
WHERE id = ANY (:ids);
```

**Retention and access.** The value is the original record, so it can carry chat text and an account id: **give the table the same access
and the same retention rules as the event store.** Nothing purges it. A job (not a migration) can delete the old resolved rows, which the
partial index on `resolved_at` serves:

```sql
DELETE FROM dead_letter.dead_letters WHERE resolved_at < now() - interval '30 days';
```

## Run

```bash
make install                         # once: the migrate CLI
make migrations/debug                # the DSN it will use (password hidden)
make migrations/up                   # every pending migration
make migrations/up FLOW=camel_conversation           # one folder
make migrations/version              # the recorded version of each folder
make migrations/down FLOW=camel_conversation CONFIRM=yes   # drops that folder's tables and rows
make migrations/new FLOW=camel_conversation NAME=add_something   # the next numbered pair
make migrations/test                 # the idempotency check, on a throwaway Postgres in Docker
make database/create DATABASE=agentwebui   # a database of its own, when it is missing (see below)
make web-ui/setup                    # the Agent Web UI: its database, its tables, and the DB_URL it needs
```

- **Target:** the shared cluster's Postgres, `postgres://postgres@localhost:5432/postgres?sslmode=disable`. Another database:
  `make migrations/up MIGRATIONS_DB_DSN=postgres://...` (nothing is read from `.env`).
- **`SERVICE` and `FLOW`:** each is `all` (default) or a folder name. `up`, `down` and `version` accept `all`; `goto`, `force` and `new`
  need one service and one flow. `down` runs backwards.
- **A database of its own:** the migrations create schemas and tables, never a database. A service that keeps its tables in a database of
  its own needs `make database/create DATABASE=<name>` first (`scripts/create-database.sh`): it creates it when it is missing and says
  so when it is there, and the name is lower-case letters, digits and `_`. It reaches the server through `psql` when that is installed, or
  through `docker exec` in `yape-postgres` (the cluster's Postgres; `PG_CONTAINER` names another container). The Agent Web UI uses
  `agentwebui`: [`make web-ui/setup`](#the-agent-web-ui-iape-ui) does it. (`up` with the default `SERVICE=all` on the shared `postgres`
  database also creates the empty schema `web_ui` there, which nothing uses.)
- **Existing tables:** every statement is `IF NOT EXISTS`, so `up` also works on a database that already has the tables: it keeps the
  rows and records the version.
- **Limit of `IF NOT EXISTS`:** it makes `up` safe to repeat but cannot change a table that already exists. Editing a `CREATE TABLE`
  (for example adding a column) does not change a table that is already there: a change to existing tables is a **new numbered
  migration** with `ALTER TABLE`, never an edit of an old file.
- **A recorded version above the folder's latest migration:** `up` resets the record to the latest migration the folder has, says so,
  and goes on. The tables are not touched. A dirty record (a migration that failed half way) is left alone: `migrate` stops and a person
  decides.
- `scripts/migrate.sh` holds the folder discovery and the version-table name; `scripts/check-migrations.sh` is `make migrations/test`.

## What `make migrations/test` checks

On a throwaway Postgres in Docker (the cluster is not touched). For each folder: a second `up` fails nothing and leaves the schema
identical (tables, columns, constraints, indexes, comments); `down` runs twice and leaves no table; `up` after `down` gives the same
schema. Through `migrate`: a second `up` says `no change`; `up` over existing tables without version tables changes nothing; a recorded
version above the latest migration is reset without touching the tables; a dirty version is not reset silently. After `up`, nothing exists in `public` but the version tables, the four schemas exist, the publication covers only the event store table and an `UPDATE` of it is refused; after `down`, the publication and the schemas are gone. For the dead-letter table it also checks what a consumer relies on: a minimal row is accepted and starts `open` on attempt 1; the same source record twice is refused, and `ON CONFLICT DO NOTHING` makes the retry harmless; another service may dead-letter the same record; a negative offset, a status outside the three, an open row with a resolution time and a resolved row without one are all refused; and a record with a NUL and bytes that are not UTF-8 comes back byte for byte. A new folder is covered without editing the script. Last run: all 54 checks passed.

## The Agent Web UI (iApe-UI)

`iApe-UI` (the web UI for an agent) creates no table and knows nothing of these migrations: it expects its
tables in the schema `web_ui` of the database its `DB_URL` points to, and stops at start when they are not there. They are defined
here, in `migrations/web_ui/chat/`: `users`, `sessions`, `conversations` and `messages`, with the version table
`web_ui_chat_schema_migrations` in `public`. It keeps them in a database of its own, `agentwebui`, not in the shared `postgres`.

```bash
make web-ui/setup                    # create agentwebui when it is missing, apply web_ui/chat to it, print the DB_URL
make web-ui/setup WEB_UI_DATABASE=other_name       # another database name
make web-ui/setup MIGRATIONS_DB_DSN=postgres://user:password@host:5432/postgres?sslmode=disable   # another server
```

It prints the `DB_URL` for the web UI's settings, for example (the cluster's Postgres trusts local connections, so no password):

```
DB_URL="postgres://postgres@localhost:5432/agentwebui?sslmode=disable&search_path=web_ui"
```

`search_path=web_ui` is how the web UI finds its tables, because every name here is qualified with the schema and the web UI's queries
are not. Running `make web-ui/setup` again changes nothing, and it is also what to run after a new migration is added to the folder:
the web UI never changes its tables itself. The web UI's integration tests build the same tables from a copy of the two `up` files
(`it/internal/pgenv/schema.sql` in that repository): refresh the copy when the folder changes.

## Adding a table

1. `make migrations/new FLOW=<flow> NAME=<snake_case>` (or a new folder `migrations/<service>/<flow>/` for a new set of tables).
2. Write the `up` with `IF NOT EXISTS` and the `down` with `IF EXISTS`; comment every table and column.
3. `make migrations/test`, then `make migrations/up`.
4. In the service's repo, document the table and point to the folder here.
