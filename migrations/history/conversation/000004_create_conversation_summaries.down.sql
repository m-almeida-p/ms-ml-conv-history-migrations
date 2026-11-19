-- Drops the table and its index. The conversation list reads it, so down-migrate only with the service stopped.
-- Up again rebuilds the rows from conversation_messages.
DROP TABLE IF EXISTS history.conversation_summaries;
