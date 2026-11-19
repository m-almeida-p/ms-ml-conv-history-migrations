-- Conversation history, part 1: the schema.
-- The tables of this flow (history/conversation) live in the schema `history`, not in `public`. Every name in the later
-- migrations is qualified with it, because migrate runs with the default search_path.
-- The version table of this folder (history_conversation_schema_migrations) stays in public: migrate creates it before the
-- first migration runs, when this schema does not exist yet.
CREATE SCHEMA IF NOT EXISTS history;

COMMENT ON SCHEMA history IS
    'Conversation history: the inbox, the chat messages, the conversation summaries and the flow-segments view. Written by ms-ml-conv-history-bs and by the Camel consumers that share its tables.';
