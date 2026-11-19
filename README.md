# ms-ml-conv-history-migrations

The database migrations of the conversation pipeline: the agent's event store, the publication Debezium reads, and the history tables built
from it. The SQL here is the definition of the schemas: the services that use the tables (`ms-ml-genai-agents-bs`,
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

The history tables, the view, the schema `camel_history` and the history version tables of the shared cluster's Postgres were dropped, so
those migrations can be applied. **The event store was not**: the cluster still has `public.conversation_events` (emptied), its trigger,
the publication and slot `conversation_events`, the connector bound to them, and the version table `agent_conversation_schema_migrations` at
version 2. `make migrations/up` would then create a second, empty event store in `event_store` and fail to create the publication, which
already exists. Move it in this order: stop the connector, drop the old publication and slot and `public.conversation_events` with the old
version table, `make migrations/up`, then give the connector the settings above and start it.

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
```

- **Target:** the shared cluster's Postgres, `postgres://postgres@localhost:5432/postgres?sslmode=disable`. Another database:
  `make migrations/up MIGRATIONS_DB_DSN=postgres://...` (nothing is read from `.env`).
- **`SERVICE` and `FLOW`:** each is `all` (default) or a folder name. `up`, `down` and `version` accept `all`; `goto`, `force` and `new`
  need one service and one flow. `down` runs backwards.
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
version above the latest migration is reset without touching the tables; a dirty version is not reset silently. After `up`, nothing exists in `public` but the version tables, the three schemas exist, the publication covers only the event store table and an `UPDATE` of it is refused; after `down`, the publication and the schemas are gone. A new folder is covered without editing the script. Last run: all 35 checks passed.

## Adding a table

1. `make migrations/new FLOW=<flow> NAME=<snake_case>` (or a new folder `migrations/<service>/<flow>/` for a new set of tables).
2. Write the `up` with `IF NOT EXISTS` and the `down` with `IF EXISTS`; comment every table and column.
3. `make migrations/test`, then `make migrations/up`.
4. In the service's repo, document the table and point to the folder here.
