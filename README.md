# ms-ml-conv-history-migrations

The database migrations of the conversation history. The SQL here is the definition of the schemas: the services that use the tables
(`ms-ml-conv-history-bs`, `ms-ml-camel-conv-history-bs`, `ms-ml-conv-history-consumer`) do not create them. They are applied with
[golang-migrate](https://github.com/golang-migrate/migrate).

## Where these came from

They were copied, unchanged, from `ml-genai-agents-bs-testing` (`migrations/history/`), where the conversation tables used to live
together with the agent's `conversation_events`. That repo keeps the agent's migrations (`migrations/agent/`); the history ones now
have their own repo, so a change to the history tables does not need the producer's repo. The SQL is byte-identical to the source. The
runner (`Makefile`, `scripts/`) is the same one, reduced to the `history` service.

Nothing was removed from the source repo. The history folders there are now duplicates: delete them there when this repo is the one the
services use, so there is one place for them.

## Layout

`migrations/<service>/<flow>/`: one folder per owning service and per set of tables. A new set of tables is a new folder; nothing else
lists the folders. Every folder numbers its files from `000001` and records its applied version in `<service>_<flow>_schema_migrations`,
so the folders evolve apart in the same database.

| Folder | Tables | Service | Version table |
|---|---|---|---|
| `migrations/history/conversation/` | `conversation_inbox`, `conversation_messages`, `conversation_summaries`, the view `conversation_flow_segments`, in the schema `public` | `ms-ml-conv-history-bs` (the Go service) | `history_conversation_schema_migrations` |
| `migrations/history/camel_conversation/` | the same three tables in the schema `camel_history`, and the two maps to Microsoft Foundry (`foundry_conversation_map`, `foundry_item_map`) | `ms-ml-camel-conv-history-bs`, `ms-ml-conv-history-consumer` | `history_camel_conversation_schema_migrations` |

The folder and table names are the ones the cluster already records (`history_conversation` at version 3, `history_camel_conversation`
at version 4, checked), so running `up` from here on that database changes nothing.

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
version above the latest migration is reset without touching the tables; a dirty version is not reset silently. A new folder is covered
without editing the script. Last run: all 21 checks passed.

## Adding a table

1. `make migrations/new FLOW=<flow> NAME=<snake_case>` (or a new folder `migrations/<service>/<flow>/` for a new set of tables).
2. Write the `up` with `IF NOT EXISTS` and the `down` with `IF EXISTS`; comment every table and column.
3. `make migrations/test`, then `make migrations/up`.
4. In the service's repo, document the table and point to the folder here.
