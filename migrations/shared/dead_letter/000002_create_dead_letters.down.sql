-- Drops the table with its indexes and every dead letter in it. A dead letter holds the only copy of a record the consumer refused,
-- so down-migrate only after the open rows were replayed or you no longer want them.
DROP TABLE IF EXISTS dead_letter.dead_letters;
