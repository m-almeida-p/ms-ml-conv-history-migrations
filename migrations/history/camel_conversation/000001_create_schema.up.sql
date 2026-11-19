-- Camel conversation history, part 1: the schema.
-- The tables of this flow (history/camel_conversation) live in the schema `camel_history`, apart from the schema `history` of
-- history/conversation, so the Camel consumer's rows and the Go consumer's are never mixed. Every name in the later migrations is
-- qualified with it, because migrate runs with the default search_path.
-- The version table of this folder (history_camel_conversation_schema_migrations) stays in public: migrate creates it before the
-- first migration runs, when this schema does not exist yet.
CREATE SCHEMA IF NOT EXISTS camel_history;

COMMENT ON SCHEMA camel_history IS
    'Conversation history written by the Camel Karavan consumer (ms-ml-camel-conv-history-bs): its own copy of the history tables and the maps to Microsoft Foundry. Same tables as history.conversation_*, kept apart from them.';
