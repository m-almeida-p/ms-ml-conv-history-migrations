-- Drops the publication. The connector has no source until it is recreated, so stop it first. The slot, which belongs to the
-- connector, is not touched: drop it with the connector (SELECT pg_drop_replication_slot('conversation_events')).
DROP PUBLICATION IF EXISTS conversation_events;
