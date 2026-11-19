-- Drops both tables, with their indexes and rows. The history is rebuilt from Kafka and the agent's conversation_events.
DROP TABLE IF EXISTS history.conversation_messages;
DROP TABLE IF EXISTS history.conversation_inbox;
