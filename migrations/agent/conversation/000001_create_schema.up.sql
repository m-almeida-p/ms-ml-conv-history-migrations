-- Event store, part 1: the schema.
-- The agent's event store lives in the schema `event_store`, not in `public`. Every name in the later migrations is
-- qualified with it, because migrate runs with the default search_path.
-- The version table of this folder (agent_conversation_schema_migrations) stays in public: migrate creates it before the
-- first migration runs, when this schema does not exist yet.
CREATE SCHEMA IF NOT EXISTS event_store;

COMMENT ON SCHEMA event_store IS
    'The write side: the append-only log of what happened in a conversation (conversation_events), written by ms-ml-genai-agents-bs and streamed by Debezium to Kafka. The history schemas are built from it.';
