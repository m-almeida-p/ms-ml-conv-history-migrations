-- Drops both tables, with their indexes and rows. The history is rebuilt from Kafka.
-- Run after 000003's down, which drops conversation_summaries. The schema is dropped by 000001's down.
DROP TABLE IF EXISTS camel_history.conversation_messages;
DROP TABLE IF EXISTS camel_history.conversation_inbox;
