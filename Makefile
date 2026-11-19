# Migrations for the conversation history tables, run with golang-migrate (`make install`).
# This repo is the single place for them: migrations/<service>/<flow>/, one folder per
# owning service and per flow. A new flow is a new folder.
#
#   migrations/history/conversation/        conversation_inbox, conversation_messages, conversation_summaries,
#                                           the view conversation_flow_segments            (ms-ml-conv-history-bs, schema public)
#   migrations/history/camel_conversation/  the same three tables in the schema camel_history, and the two
#                                           maps to Microsoft Foundry                      (ms-ml-camel-conv-history-bs)
#
# Each folder records its version in its own table, <service>_<flow>_schema_migrations,
# so they evolve apart in one database. SERVICE (history, the default) and FLOW (conversation,
# camel_conversation; default all) pick folders.
# No environment file is read: the target defaults to the shared cluster's Postgres
# and is overridden on the command line, `make migrations/up MIGRATIONS_DB_DSN=postgres://...`.

SERVICE ?= history
FLOW ?= all
MIGRATIONS_ROOT ?= ./migrations
ifeq ($(strip $(MIGRATIONS_DB_DSN)),)
# The shared cluster's Postgres (trust auth, no password).
MIGRATIONS_DB_DSN := postgres://postgres@localhost:5432/postgres?sslmode=disable
endif
MIGRATE ?= migrate
export MIGRATIONS_ROOT MIGRATIONS_DB_DSN MIGRATE

RUN_MIGRATE = ./scripts/migrate.sh $(SERVICE) $(FLOW)

# The DSN with any password hidden, for output.
MASKED_DSN = $(shell echo '$(MIGRATIONS_DB_DSN)' | sed -E 's\#(://[^:/@]+):[^@/]+@\#\1:****@\#')

## help: list the targets
.PHONY: help
help:
	@sed -n 's/^##//p' $(MAKEFILE_LIST) | column -t -s ':' | sed -e 's/^/ /'

## install: install the migrate CLI (postgres driver)
.PHONY: install
install:
	go install -tags 'postgres' github.com/golang-migrate/migrate/v4/cmd/migrate@latest

## migrations/check: verify the CLI and the folders
.PHONY: migrations/check
migrations/check:
	@command -v $(MIGRATE) >/dev/null || { echo "Error: '$(MIGRATE)' not found. Run: make install"; exit 1; }
	@test -d "$(MIGRATIONS_ROOT)" || { echo "Error: MIGRATIONS_ROOT '$(MIGRATIONS_ROOT)' is not a directory"; exit 1; }

## migrations/debug: show the settings (password hidden)
.PHONY: migrations/debug
migrations/debug:
	@echo "SERVICE:           $(SERVICE)"
	@echo "FLOW:              $(FLOW)"
	@echo "MIGRATIONS_ROOT:   $(MIGRATIONS_ROOT)"
	@echo "MIGRATIONS_DB_DSN: $(MASKED_DSN)"

## migrations/up: apply every pending migration (flows in name order)
.PHONY: migrations/up
migrations/up: migrations/check
	@echo "Applying migrations to $(MASKED_DSN)"
	@$(RUN_MIGRATE) up

## migrations/down: revert the selected migrations (drops their tables); needs CONFIRM=yes
.PHONY: migrations/down
migrations/down: migrations/check
	@test "$(CONFIRM)" = "yes" || { echo "This drops the tables of SERVICE=$(SERVICE) FLOW=$(FLOW) with all their rows. Re-run with CONFIRM=yes"; exit 1; }
	@$(RUN_MIGRATE) down

## migrations/goto: migrate one service and flow to version GOTO
.PHONY: migrations/goto
migrations/goto: migrations/check
	@test -n "$(GOTO)" || { echo "Error: set GOTO=<version>"; exit 1; }
	@$(RUN_MIGRATE) goto $(GOTO)

## migrations/force: set one service and flow's recorded version to GOTO without running anything
.PHONY: migrations/force
migrations/force: migrations/check
	@test -n "$(GOTO)" || { echo "Error: set GOTO=<version>"; exit 1; }
	@$(RUN_MIGRATE) force $(GOTO)

## migrations/version: show the recorded version of each folder
.PHONY: migrations/version
migrations/version: migrations/check
	@$(RUN_MIGRATE) version

## migrations/test: check every folder is idempotent, on a throwaway Postgres in Docker
.PHONY: migrations/test
migrations/test: migrations/check
	@./scripts/check-migrations.sh

## migrations/new: create the next numbered migration, SERVICE=history FLOW=<flow> NAME=<snake_case>
.PHONY: migrations/new
migrations/new: migrations/check
	@test -n "$(NAME)" || { echo "Error: set NAME=<snake_case_name>"; exit 1; }
	@$(RUN_MIGRATE) new $(NAME)
