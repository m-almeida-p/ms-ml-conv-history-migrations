-- Dead letters, part 2: the table.
-- Every statement is IF NOT EXISTS, so running it over an existing table is safe.
--
-- A consumer writes one row for each record it refuses for good (a poison record: it breaks the contract, cannot be decoded, or the store
-- refuses the data) and for each unexpected error that was retried and still failed. A failure that is not the record's fault (the database
-- or the registry is down) is retried in place and never lands here. The consumer commits the offset after the row is written, so a record
-- is never lost: if the insert fails, the record is read again.
--
-- The same record can arrive twice (a retry after the insert succeeded but before the commit), so the source of the record is a unique
-- key and the consumer inserts with ON CONFLICT DO NOTHING.
--
-- The record is kept as bytes, exactly as Kafka delivered it. Text would not do: a record can hold a NUL or bytes that are not UTF-8, which
-- is often why it was refused, and a replay must publish the same bytes. THE VALUE HOLDS THE ORIGINAL RECORD, which can carry chat text and
-- an account id: give this table the same access and the same retention rules as the event store.
CREATE TABLE IF NOT EXISTS dead_letter.dead_letters (
    id               BIGINT       GENERATED ALWAYS AS IDENTITY,
    service          TEXT         NOT NULL,
    source_topic     TEXT         NOT NULL,
    source_partition INT          NOT NULL CHECK (source_partition >= 0),
    source_offset    BIGINT       NOT NULL CHECK (source_offset >= 0),
    source_timestamp TIMESTAMPTZ,
    record_key       BYTEA,
    record_value     BYTEA,
    headers          JSONB        NOT NULL DEFAULT '{}'::jsonb,
    reason           TEXT         NOT NULL,
    field            TEXT,
    detail           TEXT,
    exception_class  TEXT,
    attempt          INT          NOT NULL DEFAULT 1 CHECK (attempt >= 1),
    status           TEXT         NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'replayed', 'discarded')),
    failed_at        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    resolved_at      TIMESTAMPTZ,
    resolution_note  TEXT,
    CONSTRAINT dead_letters_pkey PRIMARY KEY (id),
    CONSTRAINT dead_letters_source_key UNIQUE (service, source_topic, source_partition, source_offset),
    -- A row is resolved exactly when it is not open: no resolved row without a time, no open row with one.
    CONSTRAINT dead_letters_resolved_check CHECK ((status = 'open') = (resolved_at IS NULL))
);

-- The queue of work: what a service still has to look at, oldest first.
CREATE INDEX IF NOT EXISTS dead_letters_queue_idx
    ON dead_letter.dead_letters (service, status, failed_at);

-- Counting and searching by why a record was refused.
CREATE INDEX IF NOT EXISTS dead_letters_reason_idx
    ON dead_letter.dead_letters (reason);

-- The purge of old resolved rows reads only the resolved ones.
CREATE INDEX IF NOT EXISTS dead_letters_resolved_idx
    ON dead_letter.dead_letters (resolved_at)
    WHERE resolved_at IS NOT NULL;

COMMENT ON TABLE  dead_letter.dead_letters IS
    'A record a consumer refused for good, kept as received so it can be inspected and replayed. One row per source record and service. Holds the original record: same access and retention as the event store.';
COMMENT ON COLUMN dead_letter.dead_letters.id IS
    'Surrogate key. The source of the record, not this id, is what identifies a dead letter.';
COMMENT ON COLUMN dead_letter.dead_letters.service IS
    'Who dead-lettered it: the consumer group, such as ms-ml-conv-history-consumer. The same record can be dead-lettered by two services, each with its own row.';
COMMENT ON COLUMN dead_letter.dead_letters.source_topic IS
    'The Kafka topic the record was read from.';
COMMENT ON COLUMN dead_letter.dead_letters.source_partition IS
    'The partition of the record. With the topic and the offset, where to find it in Kafka.';
COMMENT ON COLUMN dead_letter.dead_letters.source_offset IS
    'The offset of the record in its partition. Together with service, topic and partition, the unique key: a retried insert changes nothing.';
COMMENT ON COLUMN dead_letter.dead_letters.source_timestamp IS
    'The timestamp Kafka gave the record, when the consumer knows it.';
COMMENT ON COLUMN dead_letter.dead_letters.record_key IS
    'The key of the record, byte for byte, or NULL when it had none.';
COMMENT ON COLUMN dead_letter.dead_letters.record_value IS
    'The value of the record, byte for byte, including any Schema Registry header. A replay publishes these bytes again. Holds the original data: treat it like the event store.';
COMMENT ON COLUMN dead_letter.dead_letters.headers IS
    'The Kafka headers of the record as a JSON object, name to text; NUL-free text only (binary headers are not kept).';
COMMENT ON COLUMN dead_letter.dead_letters.reason IS
    'Why it was refused, as the consumer names it: no-schema-header, schema-id, schema-violation, json, field-missing, field-malformed, field-range, payload, metadata, occurred-at, store-rejected, projection-missing, foundry-rejected or unexpected. An open list: a new consumer may add its own.';
COMMENT ON COLUMN dead_letter.dead_letters.field IS
    'The field that broke the rule, or the SQLSTATE of a refusal by the store (sqlstate-22021), or the exception class of an unexpected error. NULL when there is none.';
COMMENT ON COLUMN dead_letter.dead_letters.detail IS
    'A human message about the refusal. Written for people: it must not repeat the data of the record.';
COMMENT ON COLUMN dead_letter.dead_letters.exception_class IS
    'The class of the exception that ended the attempts, for an unexpected error; NULL otherwise.';
COMMENT ON COLUMN dead_letter.dead_letters.attempt IS
    'How many times the consumer tried the record before giving up. 1 for a record refused at once.';
COMMENT ON COLUMN dead_letter.dead_letters.status IS
    'open: nobody has dealt with it. replayed: it was published again. discarded: someone decided it is not worth keeping or replaying.';
COMMENT ON COLUMN dead_letter.dead_letters.failed_at IS
    'When the consumer gave up on the record.';
COMMENT ON COLUMN dead_letter.dead_letters.resolved_at IS
    'When it was replayed or discarded. NULL exactly while the status is open.';
COMMENT ON COLUMN dead_letter.dead_letters.resolution_note IS
    'Who resolved it and why, in a sentence, for example "fixed in the decoder, republished with kafka-replay".';
