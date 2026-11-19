-- Conversation history, part 3: a conversation cut into segments of a flow.
-- Every name is qualified with the schema history (created by 000001). Every statement is repeatable, so running it over an existing view is safe.
--
-- The inbox stamps each fact with the flow that was active when it arrived. That
-- leaves two messages at the edge of a flow on the wrong side of it: the user
-- message that opens a flow arrives before the dispatcher routes it, and the one
-- that leaves a flow arrives while the flow is still active. This view reads the
-- facts again by who handled them.
--
--   * A user message (UserMessageSent) belongs to the flow of the next fact that is
--     not a user message, the one that handled it. With no next fact it keeps the
--     flow it was written in.
--   * The facts of the conversation itself (the start and the close, a blocked
--     message, the guardrail reply, a failed turn) take the flow of the fact before
--     them, so they never split a segment.
--   * A segment is a stretch of consecutive facts in one flow (or in none). It also ends
--     at a ConfirmationResolved: the first user message after one opens the next segment,
--     which is how two transfers in a row are told apart.
--   * The outcome of a segment comes from its payment facts. The decision of its last
--     ConfirmationResolved (approved, rejected or failed); abandoned, when a card was
--     offered, never resolved and another segment followed; expired, when it was the
--     last segment and ten minutes have passed (the approval's lifetime); open, while it
--     has not; none, when the segment offered no card.
--
-- The view reads two fields from the payload the inbox stored, which is never
-- upcast: confirmation_ref of any event that carries one, and decision of
-- ConfirmationResolved. A new payload version of those events needs a CASE on
-- event_version here. The agent's history_view_contract_test.go lists the versions
-- this view reads and fails when an event moves past them.
--
-- Every step is a window over (conversation_id, ...), never a correlated lookup,
-- so a filter on conversation_id reaches the inbox's primary key and one
-- conversation reads only its own rows. The first step is NOT MATERIALIZED for the
-- same reason: it is read twice, and a materialized copy would be built whole.
CREATE OR REPLACE VIEW history.conversation_flow_segments AS
WITH events AS NOT MATERIALIZED (
    SELECT conversation_id, sequence, event_name, flow, occurred_at,
           payload ->> 'confirmation_ref' AS ref,
           payload ->> 'decision'         AS decision,
           CASE
               WHEN event_name = 'UserMessageSent' THEN 'user'
               WHEN event_name IN ('ConversationStarted', 'ConversationClosed', 'UserMessageBlocked',
                                   'GuardrailResponseSent', 'AgentResponseFailed') THEN 'conversation'
               ELSE 'fact'
           END AS kind
    FROM history.conversation_inbox
),
-- Counting the facts from each row to the end of the conversation gives a user
-- message and the fact that handled it the same number, so the pair shares a group.
grouped AS (
    SELECT *,
           sum((kind = 'fact')::int) OVER (PARTITION BY conversation_id ORDER BY sequence DESC) AS facts_from_here
    FROM events
    WHERE kind <> 'conversation'
),
handled AS (
    SELECT conversation_id, sequence, event_name, kind, ref, decision, occurred_at,
           CASE
               WHEN kind = 'user' AND bool_or(kind = 'fact') OVER pair
                   THEN (array_agg(flow) FILTER (WHERE kind = 'fact') OVER pair)[1]
               ELSE flow
           END AS handled_flow,
           true AS is_handled
    FROM grouped
    WINDOW pair AS (PARTITION BY conversation_id, facts_from_here)
),
-- A fact of the conversation itself carries the flow of the handled fact before it:
-- the number of handled facts so far names the segment that fact starts.
merged AS (
    SELECT conversation_id, sequence, event_name, kind, ref, decision, occurred_at, handled_flow, is_handled
    FROM handled
    UNION ALL
    SELECT conversation_id, sequence, event_name, kind, ref, decision, occurred_at, NULL, false
    FROM events
    WHERE kind = 'conversation'
),
placed AS (
    SELECT conversation_id, sequence, event_name, kind, ref, decision, occurred_at,
           CASE
               WHEN is_handled THEN handled_flow
               ELSE max(handled_flow) FILTER (WHERE is_handled)
                    OVER (PARTITION BY conversation_id, handled_so_far)
           END AS segment_flow
    FROM (
        SELECT *, sum(is_handled::int) OVER (PARTITION BY conversation_id ORDER BY sequence) AS handled_so_far
        FROM merged
    ) m
),
counted AS (
    SELECT *,
           segment_flow IS DISTINCT FROM lag(segment_flow) OVER w
               OR row_number() OVER w = 1 AS flow_changed,
           count(*) FILTER (WHERE event_name = 'ConfirmationResolved')
               OVER (PARTITION BY conversation_id ORDER BY sequence ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS resolved_before
    FROM placed
    WINDOW w AS (PARTITION BY conversation_id ORDER BY sequence)
),
marked AS (
    SELECT *,
           flow_changed
           OR (kind = 'user' AND resolved_before > coalesce(
                  max(CASE WHEN kind = 'user' THEN resolved_before END)
                      OVER (PARTITION BY conversation_id ORDER BY sequence ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)) AS starts
    FROM counted
),
numbered AS (
    SELECT *, sum(starts::int) OVER (PARTITION BY conversation_id ORDER BY sequence) AS segment
    FROM marked
),
segments AS (
    SELECT conversation_id, segment, segment_flow AS flow,
           min(sequence) AS from_sequence, max(sequence) AS to_sequence, count(*) AS events,
           min(occurred_at) AS started_at, max(occurred_at) AS ended_at,
           (array_agg(ref ORDER BY sequence) FILTER (WHERE ref IS NOT NULL))[1] AS confirmation_ref,
           (array_agg(decision ORDER BY sequence DESC) FILTER (WHERE event_name = 'ConfirmationResolved'))[1] AS decision,
           bool_or(event_name = 'ConfirmationRequested') AS offered_a_card
    FROM numbered
    GROUP BY conversation_id, segment, segment_flow
)
SELECT conversation_id, segment::int AS segment, flow, from_sequence, to_sequence, events::int AS events,
       started_at, ended_at, confirmation_ref,
       CASE
           WHEN decision IS NOT NULL THEN decision
           WHEN NOT offered_a_card THEN 'none'
           WHEN segment < max(segment) OVER (PARTITION BY conversation_id) THEN 'abandoned'
           WHEN ended_at < now() - interval '10 minutes' THEN 'expired'
           ELSE 'open'
       END AS outcome
FROM segments;

COMMENT ON VIEW history.conversation_flow_segments IS
    'A conversation cut into segments of a flow, one row per segment, read from conversation_inbox. A user message belongs to the flow that handled it, the conversation''s own facts never split a segment, and a segment ends at its resolution. See the comment at the top of the migration for the rules.';
COMMENT ON COLUMN history.conversation_flow_segments.conversation_id IS 'The conversation.';
COMMENT ON COLUMN history.conversation_flow_segments.segment IS 'Position of the segment in the conversation, from 1.';
COMMENT ON COLUMN history.conversation_flow_segments.flow IS 'The flow of the segment, such as p2p, or NULL for a segment outside any flow.';
COMMENT ON COLUMN history.conversation_flow_segments.from_sequence IS 'Sequence of the first fact of the segment.';
COMMENT ON COLUMN history.conversation_flow_segments.to_sequence IS 'Sequence of the last fact of the segment.';
COMMENT ON COLUMN history.conversation_flow_segments.events IS 'How many facts the segment holds.';
COMMENT ON COLUMN history.conversation_flow_segments.started_at IS 'When the first fact of the segment happened.';
COMMENT ON COLUMN history.conversation_flow_segments.ended_at IS 'When the last fact of the segment happened.';
COMMENT ON COLUMN history.conversation_flow_segments.confirmation_ref IS 'Reference of the card the segment offered, from its payment facts, or NULL.';
COMMENT ON COLUMN history.conversation_flow_segments.outcome IS 'approved, rejected or failed from the resolution; abandoned, expired or open for a card never resolved; none for a segment that offered no card.';
