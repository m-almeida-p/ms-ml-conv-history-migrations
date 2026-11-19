-- Event store, part 4: the publication Debezium reads.
-- Debezium's PostgreSQL connector reads the table through a publication and a replication slot. The slot belongs to the
-- connector (it is created and dropped with it, and cannot live in a migration), but the publication is plain SQL, so it is
-- defined here and the connector is told not to create its own (publication.autocreate.mode=disabled).
--
-- It publishes every operation, as the one the connector used to create did. The append-only trigger refuses UPDATE, so in
-- practice a row is published once, when it is inserted. The connector's settings that go with this migration are in README.md.
--
-- CREATE PUBLICATION has no IF NOT EXISTS, so the check is explicit and running this again changes nothing.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'conversation_events') THEN
        CREATE PUBLICATION conversation_events FOR TABLE event_store.conversation_events;
    END IF;
END
$$;

COMMENT ON PUBLICATION conversation_events IS
    'What Debezium reads: the rows of event_store.conversation_events. The connector conversation-events is set to use it and not to create its own.';
