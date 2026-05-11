-- 009_clear_leaked_recaps.sql
--
-- One-off cleanup for rows where the server's `/weekly-recap` and
-- `/coach-observation` endpoints persisted the system-prompt template
-- as the `body`. Root cause was in routes/gemini.js: the instruction
-- text was stuffed into a function-parameter `description`, which
-- Gemini's tool-use mode treats as parameter metadata and sometimes
-- echoes back verbatim as the argument value. Fix landed by moving
-- the instructions into `config.systemInstruction` and rewriting the
-- parameter descriptions to describe the parameter.
--
-- Run from the Supabase SQL editor (service_role bypasses RLS). The
-- weekly_recaps table ships without a DELETE policy on purpose
-- ("recaps are write-once"), so this cleanup cannot run from the
-- iOS client.
--
-- After this runs and the new server build is deployed, the next
-- foreground orchestrator pass on Sun >=19:00 / any time Monday will
-- find no row in the slot and regenerate cleanly.

begin;

-- weekly_recaps: match on phrases that only exist in the prompt
-- template (`description` field of the compose_weekly_recap function),
-- never in a real coach response.
delete from public.weekly_recaps
where body ilike '%you are a resurrected AI nutrition coach%'
   or body ilike '%Do NOT use shame language%'
   or body ilike '%Compose 2-3 sentences%'
   or body ilike '%Length 40-90 words%';

-- coach_observations: same anti-pattern existed in
-- compose_coach_observation. Markers lifted from that prompt.
delete from public.coach_observations
where body ilike '%you are a resurrected AI nutrition coach%'
   or body ilike '%calm, observant, never lecturing%'
   or body ilike '%Total length 30-60 words%';

commit;
