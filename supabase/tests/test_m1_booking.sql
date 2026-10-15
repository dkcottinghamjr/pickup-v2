-- Milestone 1 acceptance test, run against a scratch database.
-- Two agents (one per player) negotiate and book a singles match with no
-- human input; out-of-rules actions stop for the player's OK; the database
-- refuses double-booking; doubles fills to four; agents can't edit rules.

create table tctx (k text primary key, v text);
create function ctx(key text) returns text language sql as $$ select v from tctx where k = key $$;
create function setctx(key text, val text) returns void language sql as $$
  insert into tctx values (key, val) on conflict (k) do update set v = excluded.v $$;

-- Four players around Freedom Park, all 4.0, free Thursday 6–9 pm and Saturday 8 am–12 pm.
do $$
declare
  u uuid;
  nm text;
  fp uuid := (select id from public.courts where name = 'Freedom Park - Front');
begin
  foreach nm in array array['Daniel', 'Sam', 'Casey', 'Drew'] loop
    insert into auth.users (email, raw_user_meta_data)
    values (lower(nm) || '@example.com', jsonb_build_object('full_name', nm)) returning id into u;
    perform setctx(nm, u::text);
    update public.profiles set self_level = 4.0, onboarded = true, area_lat = 35.19, area_lng = -80.84, city = 'Charlotte' where id = u;
    insert into public.home_courts (user_id, court_id) values (u, fp);
    insert into public.availability (user_id, kind, weekday, start_time, end_time) values
      (u, 'weekly', 4, '18:00', '21:00'),
      (u, 'weekly', 6, '08:00', '12:00');
    update public.agent_rules set new_opponent_needs_ok = false where user_id = u;
  end loop;
  perform setctx('court', fp::text);
  perform setctx('court2', (select id from public.courts where name = 'Park Road Park')::text);
end $$;

-- Upcoming Thursday and Saturday, at least 3 days out, in Charlotte time.
do $$
declare
  d date := (now() at time zone 'America/New_York')::date + 3;
begin
  while extract(dow from d) <> 4 loop d := d + 1; end loop;
  perform setctx('thu', ((d + time '18:30') at time zone 'America/New_York')::text);
  perform setctx('sat', (((d + 2) + time '09:00') at time zone 'America/New_York')::text);
  perform setctx('sat10', (((d + 2) + time '10:00') at time zone 'America/New_York')::text);
  perform setctx('late', ((d + time '22:30') at time zone 'America/New_York')::text);
end $$;

-- 1. Daniel's agent sends Sam a direct singles request with two slots.
do $$
declare
  res jsonb;
begin
  res := private.call(ctx('Daniel')::uuid, 'claude-daniel', 'request_match', jsonb_build_object(
    'format', 'singles', 'invitees', jsonb_build_array(ctx('Sam')),
    'slots', jsonb_build_array(
      jsonb_build_object('start', ctx('thu'), 'court_id', ctx('court')),
      jsonb_build_object('start', ctx('sat'), 'court_id', ctx('court')))), 'req-1');
  assert res ->> 'status' = 'sent', 'request should send without approval: ' || res::text;
  perform setctx('req1', res ->> 'request_id');
  -- Same idempotency key replays instead of sending twice.
  res := private.call(ctx('Daniel')::uuid, 'claude-daniel', 'request_match', '{}'::jsonb, 'req-1');
  assert (res ->> 'replayed')::boolean, 'idempotent replay expected';
  assert (select count(*) from public.requests where creator_id = ctx('Daniel')::uuid) = 1, 'exactly one request';
end $$;

-- 2. Sam's agent sees the offer and counters with Saturday 10 am.
do $$
declare
  res jsonb;
  offer jsonb;
begin
  res := private.call(ctx('Sam')::uuid, 'claude-sam', 'needs_attention', '{}');
  assert jsonb_array_length(res -> 'incoming_offers') = 1, 'Sam should have one incoming offer: ' || res::text;
  offer := res -> 'incoming_offers' -> 0;
  assert jsonb_array_length(offer -> 'slots') = 2, 'two slots offered';
  res := private.call(ctx('Sam')::uuid, 'claude-sam', 'respond_to_offer', jsonb_build_object(
    'offer_id', offer ->> 'offer_id', 'action', 'counter',
    'slots', jsonb_build_array(jsonb_build_object('start', ctx('sat10'), 'court_id', ctx('court')))));
  assert res ->> 'status' = 'countered', 'counter should go through: ' || res::text;
  assert (res ->> 'round')::int = 2, 'round 2';
end $$;

-- 3. Daniel's agent accepts the counter: booked, with no human involved.
do $$
declare
  res jsonb;
begin
  res := private.call(ctx('Daniel')::uuid, 'claude-daniel', 'needs_attention', '{}');
  assert jsonb_array_length(res -> 'incoming_offers') = 1, 'Daniel should see the counter: ' || res::text;
  res := private.call(ctx('Daniel')::uuid, 'claude-daniel', 'respond_to_offer', jsonb_build_object(
    'offer_id', res -> 'incoming_offers' -> 0 ->> 'offer_id', 'action', 'accept', 'slot_index', 0));
  assert res ->> 'status' = 'booked', 'should book: ' || res::text;
  perform setctx('match1', res ->> 'match_id');
  assert (select status from public.matches where id = ctx('match1')::uuid) = 'booked';
  assert (select count(*) from public.match_players where match_id = ctx('match1')::uuid and status = 'confirmed') = 2;
  assert (select status from public.requests where id = ctx('req1')::uuid) = 'booked';
  assert (select count(*) from public.approvals) = 0, 'no human approvals were needed';
  assert exists (select 1 from public.events where user_id = ctx('Sam')::uuid and type = 'match_booked'), 'Sam notified';
  assert (select count(*) from public.activity_log where actor = 'agent') >= 3, 'agent actions logged';
  res := private.call(ctx('Sam')::uuid, 'claude-sam', 'list_matches', '{}');
  assert jsonb_array_length(res -> 'matches') = 1, 'Sam sees the match';
end $$;

-- 4. Outside the rules: 10:30 pm Thursday is outside availability -> needs the player's OK.
do $$
declare
  res jsonb;
begin
  res := private.call(ctx('Daniel')::uuid, 'claude-daniel', 'request_match', jsonb_build_object(
    'format', 'singles', 'invitees', jsonb_build_array(ctx('Casey')),
    'slots', jsonb_build_array(jsonb_build_object('start', ctx('late'), 'court_id', ctx('court')))));
  assert res ->> 'status' = 'needs_owner_approval', 'late slot should need approval: ' || res::text;
  assert (res -> 'reasons')::text like '%outside your weekly availability%', 'reason names availability';
  assert not exists (select 1 from public.requests where creator_id = ctx('Daniel')::uuid and status = 'open'), 'nothing sent yet';
  perform setctx('approval', res ->> 'approval_id');
  -- The agent cannot approve its own request.
  res := private.call(ctx('Daniel')::uuid, 'claude-daniel', 'decide_approval', jsonb_build_object('approval_id', ctx('approval'), 'decision', 'approve'));
  assert res -> 'error' ->> 'code' = 'app_only', 'agents cannot approve';
  -- The player approves in the app; the parked request goes out.
  res := private.call(ctx('Daniel')::uuid, null, 'decide_approval', jsonb_build_object('approval_id', ctx('approval'), 'decision', 'approve'));
  assert res -> 'result' ->> 'status' = 'sent', 'approved request sent: ' || res::text;
  assert exists (select 1 from public.offers where to_user = ctx('Casey')::uuid and status = 'pending');
end $$;

-- 5. Other rules: notice, distance, weekly cap, autonomy=ask.
do $$
declare
  res jsonb;
begin
  update public.agent_rules set autonomy = 'ask' where user_id = ctx('Drew')::uuid;
  res := private.call(ctx('Drew')::uuid, 'claude-drew', 'request_match', jsonb_build_object(
    'format', 'singles', 'mode', 'open',
    'slots', jsonb_build_array(jsonb_build_object('start', ctx('thu'), 'court_id', ctx('court')))));
  assert res ->> 'status' = 'needs_owner_approval', 'ask-first player should park: ' || res::text;
  assert (res -> 'reasons')::text like '%asks first%';
  update public.agent_rules set autonomy = 'auto', max_per_week = 0 where user_id = ctx('Drew')::uuid;
  res := private.call(ctx('Drew')::uuid, 'claude-drew', 'request_match', jsonb_build_object(
    'format', 'singles', 'mode', 'open',
    'slots', jsonb_build_array(jsonb_build_object('start', ctx('thu'), 'court_id', ctx('court2')))));
  assert (res -> 'reasons')::text like '%match limit%', 'weekly cap enforced: ' || res::text;
  update public.agent_rules set max_per_week = 3 where user_id = ctx('Drew')::uuid;
end $$;

-- 6. No double-booking: Casey invites Daniel at the time he is already booked.
do $$
declare
  res jsonb;
begin
  res := private.call(ctx('Casey')::uuid, null, 'request_match', jsonb_build_object(
    'format', 'singles', 'invitees', jsonb_build_array(ctx('Daniel')),
    'slots', jsonb_build_array(jsonb_build_object('start', ctx('sat10'), 'court_id', ctx('court2')))));
  assert res ->> 'status' = 'sent', res::text;
  res := private.call(ctx('Daniel')::uuid, null, 'respond_to_offer', jsonb_build_object(
    'offer_id', (select id from public.offers where to_user = ctx('Daniel')::uuid and status = 'pending' limit 1), 'action', 'accept'));
  assert res -> 'error' ->> 'code' = 'time_conflict', 'double-booking refused: ' || res::text;
end $$;

-- 7. Open doubles fills to four, then books.
do $$
declare
  res jsonb;
  o text;
begin
  res := private.call(ctx('Casey')::uuid, 'claude-casey', 'request_match', jsonb_build_object(
    'format', 'doubles', 'mode', 'open',
    'slots', jsonb_build_array(jsonb_build_object('start', ctx('thu'), 'court_id', ctx('court')))));
  assert res ->> 'status' = 'sent', 'doubles sent: ' || res::text;
  perform setctx('dbl', res ->> 'match_id');
  res := private.call(ctx('Drew')::uuid, 'claude-drew', 'find_open_games', '{}');
  o := res -> 'games' -> 0 ->> 'offer_id';
  assert o is not null, 'Drew finds the open game: ' || res::text;
  res := private.call(ctx('Drew')::uuid, 'claude-drew', 'respond_to_offer', jsonb_build_object('offer_id', o, 'action', 'accept'));
  assert res ->> 'status' = 'joined', res::text;
  res := private.call(ctx('Sam')::uuid, 'claude-sam', 'respond_to_offer', jsonb_build_object('offer_id', o, 'action', 'accept'));
  assert res ->> 'status' = 'joined', res::text;
  -- Daniel is free Thursday (his match is Saturday).
  res := private.call(ctx('Daniel')::uuid, 'claude-daniel', 'respond_to_offer', jsonb_build_object('offer_id', o, 'action', 'accept'));
  assert res ->> 'status' = 'booked', 'fourth player books it: ' || res::text;
  assert (select status from public.matches where id = ctx('dbl')::uuid) = 'booked';
  assert (select count(*) from public.match_players where match_id = ctx('dbl')::uuid and team = 1) = 2;
  assert (select count(*) from public.match_players where match_id = ctx('dbl')::uuid and team = 2) = 2;
end $$;

-- 8. Cancelling: early cancel by agent is fine; the slot frees up.
do $$
declare
  res jsonb;
begin
  res := private.call(ctx('Sam')::uuid, 'claude-sam', 'cancel_match', jsonb_build_object('match_id', ctx('match1'), 'reason', 'Work trip'));
  assert res ->> 'status' = 'cancelled', res::text;
  assert not (res ->> 'late')::boolean;
  assert exists (select 1 from public.events where user_id = ctx('Daniel')::uuid and type = 'match_cancelled');
  -- Daniel can now take Casey's Saturday 10 am offer.
  res := private.call(ctx('Daniel')::uuid, null, 'respond_to_offer', jsonb_build_object(
    'offer_id', (select id from public.offers where to_user = ctx('Daniel')::uuid and status = 'pending' limit 1), 'action', 'accept'));
  assert res ->> 'status' = 'booked', 'slot freed after cancel: ' || res::text;
end $$;

-- 9. Row-level security, as a signed-in agent and as the app.
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', ctx('Sam'), 'role', 'authenticated', 'client_id', 'claude-sam')::text, false);
do $$
begin
  update public.agent_rules set autonomy = 'auto', max_per_week = 21 where user_id = ctx('Sam')::uuid;
  assert (select max_per_week from public.agent_rules where user_id = ctx('Sam')::uuid) = 3, 'agents cannot change rules';
  assert (select count(*) from public.private_details) = 1, 'only own private details visible';
  update public.profiles set display_name = 'Hacked' where id = ctx('Sam')::uuid;
  assert (select display_name from public.profiles where id = ctx('Sam')::uuid) = 'Sam', 'agents cannot edit the profile';
  assert (select count(*) from public.matches where id = ctx('match1')::uuid) = 1, 'own matches visible';
  begin
    insert into public.availability (user_id, kind, weekday, start_time, end_time) values (ctx('Sam')::uuid, 'weekly', 1, '05:00', '23:00');
    assert false, 'agents must not widen availability directly';
  exception when insufficient_privilege then null;
  end;
  delete from public.home_courts where user_id = ctx('Sam')::uuid;
  assert (select count(*) from public.home_courts where user_id = ctx('Sam')::uuid) = 1, 'agents cannot change home courts';
end $$;
select set_config('request.jwt.claims', json_build_object('sub', ctx('Sam'), 'role', 'authenticated')::text, false);
do $$
begin
  update public.agent_rules set max_per_week = 5 where user_id = ctx('Sam')::uuid;
  assert (select max_per_week from public.agent_rules where user_id = ctx('Sam')::uuid) = 5, 'the app can change rules';
  begin
    update public.profiles set rating = 7.0 where id = ctx('Sam')::uuid;
    assert false, 'players must not be able to set their own rating';
  exception when insufficient_privilege then null;
  end;
  update public.profiles set display_name = 'Sam P.' where id = ctx('Sam')::uuid;
  assert (select display_name from public.profiles where id = ctx('Sam')::uuid) = 'Sam P.', 'name editable in app';
end $$;
select set_config('request.jwt.claims', json_build_object('sub', ctx('Casey'), 'role', 'authenticated')::text, false);
do $$
begin
  assert (select count(*) from public.matches where id = ctx('match1')::uuid) = 0, 'others'' matches hidden';
  assert (select count(*) from public.approvals) = 0, 'others'' approvals hidden';
end $$;
reset role;
