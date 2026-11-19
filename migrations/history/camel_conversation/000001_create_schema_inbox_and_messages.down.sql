-- Drops both tables, with their indexes and rows, and then the schema. The history is rebuilt from Kafka.
-- The schema is dropped without CASCADE on purpose: if anything else was put in it, this fails instead of deleting it.
-- Run after 000002's down, which drops conversation_summaries.
DROP TABLE IF EXISTS camel_history.conversation_messages;
DROP TABLE IF EXISTS camel_history.conversation_inbox;
DROP SCHEMA IF EXISTS camel_history;
