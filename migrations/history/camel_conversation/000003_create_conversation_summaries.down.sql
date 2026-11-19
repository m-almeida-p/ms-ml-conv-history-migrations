-- Drops the table and its index. The conversation list reads it, so down-migrate only with the consumer stopped.
-- Up again leaves it empty: the consumer fills it as it reads the topic.
DROP TABLE IF EXISTS camel_history.conversation_summaries;
