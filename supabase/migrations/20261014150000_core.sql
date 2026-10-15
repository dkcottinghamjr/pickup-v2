-- Pickup v2 — core logic.
-- Every state change goes through private.call(actor, client, action, params, key).
-- The Edge Functions (app API and MCP connector) call it with the verified
-- player id and, for agents, the OAuth client id. Nothing here is exposed
-- through the public REST API.

create table if not exists private.idempotency (
  user_id     uuid not null,
  key         text not null,
  action      text not null,
  result      jsonb not null,
  created_at  timestamptz not null default now(),
  primary key (user_id, key)
);
alter table private.idempotency enable row level security;

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

create or replace function private.err(code text, message text, next_step text default null)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('ok', false, 'error',
    jsonb_strip_nulls(jsonb_build_object('code', code, 'message', message, 'next', next_step)))
$$;

create or replace function private.tz(uid uuid)
returns text language sql stable set search_path = '' as $$
  select coalesce((select time_zone from public.profiles where id = uid), 'America/New_York')
$$;

create or replace function private.fmt_time(ts timestamptz, tz text)
returns text language sql stable set search_path = '' as $$
  select trim(to_char(ts at time zone tz, 'Dy Mon FMDD, FMHH12:MI AM'))
$$;

create or replace function private.name(uid uuid)
returns text language sql stable set search_path = '' as $$
  select coalesce(nullif((select display_name from public.profiles where id = uid), ''), 'A player')
$$;

create or replace function private.court_name(cid uuid)
returns text language sql stable set search_path = '' as $$
  select coalesce((select name from public.courts where id = cid), 'a court')
$$;

create or replace function private.slot_text(slot jsonb, tz text)
returns text language sql stable set search_path = '' as $$
  select private.fmt_time((slot ->> 'start')::timestamptz, tz) || ' at ' || private.court_name((slot ->> 'court_id')::uuid)
$$;

-- Level used for matching: Pickup Rating once established, else self-rated.
create or replace function private.level(uid uuid)
returns numeric language sql stable set search_path = '' as $$
  select coalesce(case when rated_matches >= 5 then round(rating::numeric, 1) end, self_level)
  from public.profiles where id = uid
$$;

create or replace function private.miles(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable set search_path = '' as $$
  select case when lat1 is null or lat2 is null then null else
    3958.8 * 2 * asin(sqrt(
      power(sin(radians(lat2 - lat1) / 2), 2) +
      cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
  end
$$;

-- Best known home point: exact (private) if set, else the public area.
create or replace function private.home_lat(uid uuid)
returns double precision language sql stable set search_path = '' as $$
  select coalesce((select home_lat from public.private_details where user_id = uid),
                  (select area_lat::double precision from public.profiles where id = uid))
$$;
create or replace function private.home_lng(uid uuid)
returns double precision language sql stable set search_path = '' as $$
  select coalesce((select home_lng from public.private_details where user_id = uid),
                  (select area_lng::double precision from public.profiles where id = uid))
$$;

create or replace function private.emit(uid uuid, etype text, payload jsonb, summary text)
returns void language sql set search_path = '' as $$
  insert into public.events (user_id, type, payload, summary) values (uid, etype, coalesce(payload, '{}'), summary)
$$;

create or replace function private.log(uid uuid, client text, action text, target uuid, decision text, detail jsonb default '{}')
returns void language sql set search_path = '' as $$
  insert into public.activity_log (user_id, actor, client_id, action, target_id, decision, detail)
  values (uid, case when client is null then 'app' else 'agent' end, client, action, target, decision, coalesce(detail, '{}'))
$$;

create or replace function private.have_played(a uuid, b uuid)
returns boolean language sql stable set search_path = '' as $$
  select exists (
    select 1 from public.match_players x
    join public.match_players y on y.match_id = x.match_id
    join public.matches m on m.id = x.match_id
    where x.user_id = a and y.user_id = b and m.status in ('booked', 'completed')
  )
$$;

create or replace function private.follows(a uuid, b uuid)
returns boolean language sql stable set search_path = '' as $$
  select exists (select 1 from public.follows where follower_id = a and followee_id = b and status = 'accepted')
$$;

-- Validate and normalise a slot list. Raises on bad input.
create or replace function private.check_slots(slots jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  s jsonb;
  st timestamptz;
  en timestamptz;
  out jsonb := '[]';
begin
  if slots is null or jsonb_typeof(slots) <> 'array' or jsonb_array_length(slots) = 0 then
    raise exception 'bad_slots' using detail = 'Give at least one slot: {start, end, court_id}.';
  end if;
  if jsonb_array_length(slots) > 6 then
    raise exception 'bad_slots' using detail = 'Offer at most 6 slots at a time.';
  end if;
  for s in select * from jsonb_array_elements(slots) loop
    begin
      st := (s ->> 'start')::timestamptz;
      en := coalesce((s ->> 'end')::timestamptz, st + interval '90 minutes');
    exception when others then
      raise exception 'bad_slots' using detail = 'Slot times must be ISO 8601 with a time-zone offset.';
    end;
    if st is null then
      raise exception 'bad_slots' using detail = 'Every slot needs a start time.';
    end if;
    if en <= st or en - st > interval '4 hours' or en - st < interval '30 minutes' then
      raise exception 'bad_slots' using detail = 'A slot must last between 30 minutes and 4 hours.';
    end if;
    if st < now() + interval '15 minutes' then
      raise exception 'bad_slots' using detail = 'Slots must start at least 15 minutes from now.';
    end if;
    if not exists (select 1 from public.courts where id = (s ->> 'court_id')::uuid) then
      raise exception 'bad_slots' using detail = 'Unknown court_id; use find_courts to get one.';
    end if;
    out := out || jsonb_build_array(jsonb_build_object('start', st, 'end', en, 'court_id', s ->> 'court_id'));
  end loop;
  return out;
end;
$$;

-- ---------------------------------------------------------------------------
-- Agent rules: why (if at all) an agent action needs the player's OK.
-- Returns an empty array when the action is inside the rules.
-- ---------------------------------------------------------------------------
create or replace function private.rule_reasons(actor uuid, fmt text, slots jsonb, opponents uuid[], is_open boolean)
returns text[] language plpgsql stable set search_path = '' as $$
declare
  r public.agent_rules;
  tz text := private.tz(actor);
  reasons text[] := '{}';
  s jsonb;
  st timestamptz;
  en timestamptz;
  cid uuid;
  o uuid;
  my_level numeric := private.level(actor);
  o_level numeric;
  wk_count int;
  hl double precision := private.home_lat(actor);
  hg double precision := private.home_lng(actor);
begin
  select * into r from public.agent_rules where user_id = actor;
  if r.autonomy = 'ask' then
    reasons := array_append(reasons, 'Your rules say your agent asks first');
  end if;
  if not (fmt = any (r.formats)) then
    reasons := array_append(reasons, format('%s is not in your allowed formats', initcap(fmt)));
  end if;
  if is_open and r.opponents <> 'anyone' then
    reasons := array_append(reasons, 'Open requests reach anyone, but your rules limit opponents');
  end if;

  for s in select * from jsonb_array_elements(coalesce(slots, '[]')) loop
    st := (s ->> 'start')::timestamptz;
    en := (s ->> 'end')::timestamptz;
    cid := (s ->> 'court_id')::uuid;

    if st < now() + make_interval(hours => r.min_notice_hours) then
      reasons := array_append(reasons, format('%s is less than %s hours away', private.fmt_time(st, tz), r.min_notice_hours));
    end if;

    if r.within_availability then
      if not exists (
        select 1 from public.availability a
        where a.user_id = actor and a.kind = 'weekly'
          and a.weekday = extract(dow from st at time zone tz)::int
          and (st at time zone tz)::time >= a.start_time
          and (en at time zone tz)::time <= a.end_time
          and (st at time zone tz)::date = (en at time zone tz)::date
      ) then
        reasons := array_append(reasons, format('%s is outside your weekly availability', private.fmt_time(st, tz)));
      end if;
      if exists (
        select 1 from public.availability a
        where a.user_id = actor and a.kind = 'blackout' and tstzrange(a.starts_at, a.ends_at) && tstzrange(st, en)
      ) then
        reasons := array_append(reasons, format('%s falls in a blackout you set', private.fmt_time(st, tz)));
      end if;
    end if;

    if not exists (select 1 from public.home_courts h where h.user_id = actor and h.court_id = cid) then
      if coalesce(private.miles(hl, hg, (select lat from public.courts where id = cid), (select lng from public.courts where id = cid)), 1e9)
         > r.home_courts_or_miles then
        reasons := array_append(reasons, format('%s is not a home court or within %s miles', private.court_name(cid), r.home_courts_or_miles));
      end if;
    end if;

    select count(*) into wk_count
    from public.match_players mp join public.matches m on m.id = mp.match_id
    where mp.user_id = actor and mp.status = 'confirmed' and m.status in ('forming', 'booked', 'completed')
      and date_trunc('week', m.starts_at at time zone tz) = date_trunc('week', st at time zone tz);
    if wk_count + 1 > r.max_per_week then
      reasons := array_append(reasons, format('The week of %s would go over your %s-match limit', private.fmt_time(st, tz), r.max_per_week));
    end if;
  end loop;

  foreach o in array coalesce(opponents, '{}') loop
    if r.opponents = 'following' and not private.follows(actor, o) then
      reasons := array_append(reasons, format('You don''t follow %s', private.name(o)));
    elsif r.opponents = 'list' and not (o = any (r.allow_list)) then
      reasons := array_append(reasons, format('%s is not on your list of approved players', private.name(o)));
    end if;
    if r.new_opponent_needs_ok and not private.have_played(actor, o) then
      reasons := array_append(reasons, format('First match with %s', private.name(o)));
    end if;
    o_level := private.level(o);
    if my_level is not null and o_level is not null and abs(o_level - my_level) > r.level_band then
      reasons := array_append(reasons, format('%s (%s) is outside your level range', private.name(o), o_level));
    end if;
  end loop;

  return (select coalesce(array_agg(distinct x), '{}') from unnest(reasons) x);
end;
$$;

-- Park an agent action for the player's OK.
create or replace function private.park(actor uuid, client text, action text, params jsonb, reasons text[], summary text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  a_id uuid;
begin
  insert into public.approvals (user_id, client_id, action, params, reasons, summary)
  values (actor, client, action, params, reasons, summary)
  returning id into a_id;
  perform private.emit(actor, 'approval_needed', jsonb_build_object('approval_id', a_id, 'action', action, 'reasons', reasons),
    'Your agent wants to ' || summary || ' — needs your OK.');
  perform private.log(actor, client, action, a_id, 'needs_approval', jsonb_build_object('reasons', reasons));
  return jsonb_build_object('ok', true, 'status', 'needs_owner_approval', 'approval_id', a_id, 'reasons', to_jsonb(reasons),
    'summary', 'Waiting for your player''s OK: ' || array_to_string(reasons, '; ') || '. They will see it in the Pickup app.');
end;
$$;

-- ---------------------------------------------------------------------------
-- request_match
-- params: format, mode, invitees[], partner_id, slots[], level_min, level_max, note
-- ---------------------------------------------------------------------------
create or replace function private.request_match(actor uuid, client text, p jsonb, bypass boolean default false)
returns jsonb language plpgsql set search_path = '' as $$
declare
  fmt text := coalesce(p ->> 'format', 'singles');
  md text := coalesce(p ->> 'mode', case when jsonb_array_length(coalesce(p -> 'invitees', '[]')) > 0 then 'direct' else 'open' end);
  inv uuid[] := coalesce((select array_agg(distinct x::uuid) from jsonb_array_elements_text(coalesce(p -> 'invitees', '[]')) x), '{}');
  partner uuid := nullif(p ->> 'partner_id', '')::uuid;
  slots jsonb;
  tz text := private.tz(actor);
  my_level numeric := private.level(actor);
  lmin numeric;
  lmax numeric;
  reasons text[];
  req_id uuid;
  m_id uuid;
  o uuid;
  exp timestamptz;
  offer_ids jsonb := '[]';
  o_id uuid;
  who text;
  why text;
  summary text;
begin
  if fmt not in ('singles', 'doubles') then
    return private.err('bad_format', 'format must be singles or doubles.');
  end if;
  if md not in ('direct', 'open') then
    return private.err('bad_mode', 'mode must be direct or open.');
  end if;
  begin
    slots := private.check_slots(p -> 'slots');
  exception when others then
    get stacked diagnostics why = pg_exception_detail;
    return private.err('bad_slots', coalesce(nullif(why, ''), 'Invalid slots.'),
      'Each slot needs start (ISO 8601 with offset), optional end, and a court_id from find_courts.');
  end;
  if actor = any (inv) or partner = actor then
    return private.err('bad_invitees', 'You can''t invite yourself.');
  end if;
  if md = 'direct' and cardinality(inv) = 0 and partner is null then
    return private.err('bad_invitees', 'A direct request needs at least one invitee.', 'Use find_players, or send an open request instead.');
  end if;
  if md = 'open' and cardinality(inv) > 0 then
    return private.err('bad_invitees', 'Open requests go to anyone eligible; leave invitees empty or use mode direct.');
  end if;
  if exists (select 1 from unnest(inv) x where not exists (select 1 from public.profiles where id = x)) then
    return private.err('unknown_player', 'One of the invitees is not a Pickup player.', 'Use find_players to get player ids.');
  end if;
  if fmt = 'singles' and partner is not null then
    return private.err('bad_partner', 'Singles has no partner.');
  end if;
  if fmt = 'doubles' then
    if jsonb_array_length(slots) <> 1 then
      return private.err('bad_slots', 'Doubles requests take exactly one slot, so all four players can commit to it.');
    end if;
    if cardinality(inv) > 3 then
      return private.err('bad_invitees', 'Doubles needs only 3 other players.');
    end if;
  end if;

  lmin := coalesce((p ->> 'level_min')::numeric, my_level - 0.5);
  lmax := coalesce((p ->> 'level_max')::numeric, my_level + 0.5);

  if client is not null and not bypass then
    reasons := private.rule_reasons(actor, fmt, slots, inv || case when partner is null then '{}'::uuid[] else array[partner] end, md = 'open');
    if cardinality(reasons) > 0 then
      who := case when md = 'open' then 'anyone eligible'
                  else (select string_agg(private.name(x), ', ') from unnest(inv || case when partner is null then '{}'::uuid[] else array[partner] end) x) end;
      return private.park(actor, client, 'request_match', p, reasons,
        format('send a %s request to %s for %s', fmt, who, private.slot_text(slots -> 0, tz)));
    end if;
  end if;

  select min((s ->> 'start')::timestamptz) into exp from jsonb_array_elements(slots) s;

  insert into public.requests (creator_id, format, mode, partner_id, level_min, level_max, slots, note, status, expires_at, created_via, client_id)
  values (actor, fmt, md, partner, lmin, lmax, slots, nullif(p ->> 'note', ''), 'open', exp,
          case when client is null then 'app' else 'agent' end, client)
  returning id into req_id;

  -- Doubles: the creator holds the slot from the start; the match fills up.
  if fmt = 'doubles' then
    begin
      insert into public.matches (request_id, format, starts_at, ends_at, court_id, status)
      values (req_id, 'doubles', (slots -> 0 ->> 'start')::timestamptz, (slots -> 0 ->> 'end')::timestamptz,
              (slots -> 0 ->> 'court_id')::uuid, 'forming')
      returning id into m_id;
      insert into public.match_players (match_id, user_id, team, during)
      values (m_id, actor, 1, tstzrange((slots -> 0 ->> 'start')::timestamptz, (slots -> 0 ->> 'end')::timestamptz));
    exception when exclusion_violation then
      raise exception 'You already have a match at %', private.fmt_time((slots -> 0 ->> 'start')::timestamptz, tz)
        using errcode = 'PK001';
    end;
    update public.requests set match_id = m_id where id = req_id;
  end if;

  foreach o in array (inv || case when partner is null then '{}'::uuid[] else array[partner] end) loop
    insert into public.request_invitees (request_id, user_id) values (req_id, o) on conflict do nothing;
    insert into public.offers (request_id, from_user, to_user, slots, expires_at, created_via, client_id)
    values (req_id, actor, o, slots, exp, case when client is null then 'app' else 'agent' end, client)
    returning id into o_id;
    offer_ids := offer_ids || to_jsonb(o_id);
    perform private.emit(o, 'offer_received',
      jsonb_build_object('offer_id', o_id, 'request_id', req_id, 'from', actor),
      format('%s invited you to %s%s: %s', private.name(actor), fmt,
             case when o = partner then ' as their partner' else '' end,
             (select string_agg(private.slot_text(s, private.tz(o)), ' or ') from jsonb_array_elements(slots) s)));
  end loop;

  if md = 'open' then
    insert into public.offers (request_id, from_user, to_user, slots, expires_at, created_via, client_id)
    values (req_id, actor, null, slots, exp, case when client is null then 'app' else 'agent' end, client)
    returning id into o_id;
    offer_ids := offer_ids || to_jsonb(o_id);
  end if;

  summary := format('Sent: %s %s for %s.', case when md = 'open' then 'open' else 'direct' end, fmt,
    (select string_agg(private.slot_text(s, tz), ' or ') from jsonb_array_elements(slots) s));
  perform private.log(actor, client, 'request_match', req_id, case when bypass then 'approved' else 'allowed' end, p);
  return jsonb_build_object('ok', true, 'status', 'sent', 'request_id', req_id, 'match_id', m_id,
                            'offer_ids', offer_ids, 'summary', summary);
end;
$$;

-- ---------------------------------------------------------------------------
-- respond_to_offer: accept | decline | counter
-- params: offer_id, action, slot_index (accept), slots (counter)
-- ---------------------------------------------------------------------------
create or replace function private.respond_to_offer(actor uuid, client text, p jsonb, bypass boolean default false)
returns jsonb language plpgsql set search_path = '' as $$
declare
  o public.offers;
  rq public.requests;
  act text := p ->> 'action';
  idx int := coalesce((p ->> 'slot_index')::int, 0);
  slot jsonb;
  new_slots jsonb;
  tz text := private.tz(actor);
  reasons text[];
  m_id uuid;
  my_team smallint;
  t1 int;
  t2 int;
  new_id uuid;
  lvl numeric := private.level(actor);
  other uuid;
  why text;
begin
  select * into o from public.offers where id = (p ->> 'offer_id')::uuid for update;
  if not found then
    return private.err('offer_not_found', 'No such offer.', 'Call needs_attention or find_open_games for current offers.');
  end if;
  select * into rq from public.requests where id = o.request_id for update;

  if o.to_user is not null and o.to_user <> actor then
    return private.err('not_yours', 'This offer was sent to someone else.');
  end if;
  if o.to_user is null then
    if rq.creator_id = actor then
      return private.err('not_yours', 'That''s your own open request.');
    end if;
    if lvl is not null and rq.level_min is not null and (lvl < rq.level_min or lvl > rq.level_max) then
      return private.err('level_mismatch', format('This game is for levels %s–%s.', rq.level_min, rq.level_max));
    end if;
  end if;
  if o.status <> 'pending' or rq.status <> 'open' then
    return private.err('offer_closed', format('This offer is no longer open (it was %s).', o.status),
      'Call needs_attention for current offers.');
  end if;
  if o.expires_at <= now() then
    update public.offers set status = 'expired' where id = o.id;
    return private.err('offer_expired', 'This offer has expired.');
  end if;
  other := o.from_user;

  if act = 'decline' then
    if o.to_user is null then
      perform private.log(actor, client, 'decline_offer', o.id, 'allowed');
      return jsonb_build_object('ok', true, 'status', 'declined', 'summary', 'Skipped this open game.');
    end if;
    update public.offers set status = 'declined', responded_at = now() where id = o.id;
    update public.request_invitees set status = 'declined', updated_at = now() where request_id = rq.id and user_id = actor;
    perform private.emit(other, 'offer_declined', jsonb_build_object('offer_id', o.id, 'request_id', rq.id, 'by', actor),
      format('%s can''t make it.', private.name(actor)));
    if rq.format = 'singles' and not exists (select 1 from public.offers where request_id = rq.id and status = 'pending') then
      update public.requests set status = 'expired' where id = rq.id;
      perform private.emit(rq.creator_id, 'request_closed', jsonb_build_object('request_id', rq.id),
        'No one could make your request. Try other times or an open request.');
    end if;
    perform private.log(actor, client, 'decline_offer', o.id, 'allowed');
    return jsonb_build_object('ok', true, 'status', 'declined', 'summary', format('Declined %s''s offer.', private.name(other)));
  end if;

  if act = 'counter' then
    if rq.format = 'doubles' then
      return private.err('no_counter_doubles', 'Doubles requests can''t be countered; decline and send your own request.');
    end if;
    begin
      new_slots := private.check_slots(p -> 'slots');
    exception when others then
      get stacked diagnostics why = pg_exception_detail;
      return private.err('bad_slots', coalesce(nullif(why, ''), 'Counter slots are invalid.'),
        'Each slot needs start (ISO 8601 with offset), optional end, and a court_id.');
    end;
    if client is not null and not bypass then
      reasons := private.rule_reasons(actor, rq.format, new_slots, array[other], false);
      if o.round >= 3 then
        reasons := array_append(reasons, 'Three rounds of counter-offers already; time for the players to settle it');
      end if;
      if cardinality(reasons) > 0 then
        return private.park(actor, client, 'respond_to_offer', p, reasons,
          format('counter %s with %s', private.name(other), private.slot_text(new_slots -> 0, tz)));
      end if;
    end if;
    update public.offers set status = 'countered', responded_at = now() where id = o.id;
    insert into public.offers (request_id, from_user, to_user, slots, parent_offer_id, round, expires_at, created_via, client_id)
    values (rq.id, actor, other, new_slots, o.id, o.round + 1,
            greatest(rq.expires_at, (select max((s ->> 'start')::timestamptz) from jsonb_array_elements(new_slots) s)),
            case when client is null then 'app' else 'agent' end, client)
    returning id into new_id;
    update public.requests
      set expires_at = greatest(expires_at, (select max((s ->> 'start')::timestamptz) from jsonb_array_elements(new_slots) s))
      where id = rq.id;
    perform private.emit(other, 'offer_received', jsonb_build_object('offer_id', new_id, 'request_id', rq.id, 'from', actor),
      format('%s suggested %s', private.name(actor),
        (select string_agg(private.slot_text(s, private.tz(other)), ' or ') from jsonb_array_elements(new_slots) s)));
    perform private.log(actor, client, 'counter_offer', new_id, case when bypass then 'approved' else 'allowed' end, p);
    return jsonb_build_object('ok', true, 'status', 'countered', 'offer_id', new_id, 'round', o.round + 1,
      'summary', format('Suggested %s to %s.', (select string_agg(private.slot_text(s, tz), ' or ') from jsonb_array_elements(new_slots) s), private.name(other)));
  end if;

  if act <> 'accept' then
    return private.err('bad_action', 'action must be accept, decline or counter.');
  end if;

  if idx < 0 or idx >= jsonb_array_length(o.slots) then
    return private.err('bad_slot_index', format('slot_index must be between 0 and %s.', jsonb_array_length(o.slots) - 1));
  end if;
  slot := o.slots -> idx;
  if (slot ->> 'start')::timestamptz <= now() then
    return private.err('slot_passed', 'That slot has already started.');
  end if;

  if client is not null and not bypass then
    reasons := private.rule_reasons(actor, rq.format, jsonb_build_array(slot), array[other], false);
    if cardinality(reasons) > 0 then
      return private.park(actor, client, 'respond_to_offer', p, reasons,
        format('accept %s''s %s for %s', private.name(other), rq.format, private.slot_text(slot, tz)));
    end if;
  end if;

  if rq.format = 'singles' then
    begin
      insert into public.matches (request_id, format, starts_at, ends_at, court_id, status)
      values (rq.id, 'singles', (slot ->> 'start')::timestamptz, (slot ->> 'end')::timestamptz, (slot ->> 'court_id')::uuid, 'booked')
      returning id into m_id;
      insert into public.match_players (match_id, user_id, team, during) values
        (m_id, other, 1, tstzrange((slot ->> 'start')::timestamptz, (slot ->> 'end')::timestamptz)),
        (m_id, actor, 2, tstzrange((slot ->> 'start')::timestamptz, (slot ->> 'end')::timestamptz));
    exception when exclusion_violation then
      return private.err('time_conflict', format('Someone already has a match overlapping %s.', private.fmt_time((slot ->> 'start')::timestamptz, tz)),
        'Pick another slot or counter with a different time.');
    end;
    update public.offers set status = 'accepted', accepted_slot = idx, accepted_by = actor, responded_at = now() where id = o.id;
    update public.offers set status = 'withdrawn' where request_id = rq.id and status = 'pending' and id <> o.id;
    update public.request_invitees set status = case when user_id = actor then 'accepted' else status end, updated_at = now() where request_id = rq.id;
    update public.requests set status = 'booked', match_id = m_id where id = rq.id;
    update public.profiles set matches_booked = matches_booked + 1 where id in (other, actor);
    perform private.emit(other, 'match_booked', jsonb_build_object('match_id', m_id),
      format('Booked: singles with %s, %s.', private.name(actor), private.slot_text(slot, private.tz(other))));
    perform private.emit(actor, 'match_booked', jsonb_build_object('match_id', m_id),
      format('Booked: singles with %s, %s.', private.name(other), private.slot_text(slot, tz)));
    perform private.log(actor, client, 'accept_offer', m_id, case when bypass then 'approved' else 'allowed' end, p);
    return jsonb_build_object('ok', true, 'status', 'booked', 'match_id', m_id,
      'summary', format('Booked: singles with %s, %s.', private.name(other), private.slot_text(slot, tz)));
  end if;

  -- Doubles: join the forming match.
  m_id := rq.match_id;
  select count(*) filter (where team = 1), count(*) filter (where team = 2) into t1, t2
    from public.match_players where match_id = m_id and status = 'confirmed';
  if actor = rq.partner_id then
    my_team := 1;
  elsif t2 < 2 then
    my_team := 2;
  elsif t1 < 2 and rq.partner_id is null then
    my_team := 1;
  else
    return private.err('match_full', 'This doubles match is already full.');
  end if;
  if (my_team = 1 and t1 >= 2) then
    return private.err('match_full', 'This doubles match is already full.');
  end if;
  begin
    insert into public.match_players (match_id, user_id, team, during)
    values (m_id, actor, my_team, tstzrange((slot ->> 'start')::timestamptz, (slot ->> 'end')::timestamptz));
  exception when exclusion_violation then
    return private.err('time_conflict', format('You already have a match overlapping %s.', private.fmt_time((slot ->> 'start')::timestamptz, tz)));
  when unique_violation then
    return private.err('already_in', 'You''re already in this match.');
  end;
  if o.to_user is not null then
    update public.offers set status = 'accepted', accepted_slot = 0, accepted_by = actor, responded_at = now() where id = o.id;
    update public.request_invitees set status = 'accepted', updated_at = now() where request_id = rq.id and user_id = actor;
  end if;
  perform private.emit(rq.creator_id, 'player_joined', jsonb_build_object('match_id', m_id, 'player', actor),
    format('%s joined your doubles, %s.', private.name(actor), private.slot_text(slot, private.tz(rq.creator_id))));

  if (select count(*) from public.match_players where match_id = m_id and status = 'confirmed') = 4 then
    update public.matches set status = 'booked' where id = m_id;
    update public.requests set status = 'booked' where id = rq.id;
    update public.offers set status = case when to_user is null then 'accepted' else 'withdrawn' end
      where request_id = rq.id and status = 'pending';
    update public.profiles set matches_booked = matches_booked + 1
      where id in (select user_id from public.match_players where match_id = m_id and status = 'confirmed');
    perform private.emit(mp.user_id, 'match_booked', jsonb_build_object('match_id', m_id),
      format('Booked: doubles, %s. All four players are in.', private.slot_text(slot, private.tz(mp.user_id))))
    from public.match_players mp where mp.match_id = m_id and mp.status = 'confirmed';
    perform private.log(actor, client, 'accept_offer', m_id, case when bypass then 'approved' else 'allowed' end, p);
    return jsonb_build_object('ok', true, 'status', 'booked', 'match_id', m_id,
      'summary', format('Booked: doubles, %s. All four players are in.', private.slot_text(slot, tz)));
  end if;

  perform private.log(actor, client, 'accept_offer', m_id, case when bypass then 'approved' else 'allowed' end, p);
  return jsonb_build_object('ok', true, 'status', 'joined', 'match_id', m_id,
    'summary', format('You''re in: doubles, %s. Waiting on %s more player(s).', private.slot_text(slot, tz),
      4 - (select count(*) from public.match_players where match_id = m_id and status = 'confirmed')));
end;
$$;

-- ---------------------------------------------------------------------------
-- cancel_request (creator withdraws an open request)
-- ---------------------------------------------------------------------------
create or replace function private.cancel_request(actor uuid, client text, p jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  rq public.requests;
begin
  select * into rq from public.requests where id = (p ->> 'request_id')::uuid for update;
  if not found or rq.creator_id <> actor then
    return private.err('not_found', 'No open request of yours with that id.');
  end if;
  if rq.status not in ('open', 'pending_approval') then
    return private.err('not_open', format('That request is already %s.', rq.status), 'To cancel a booked match, use cancel_match.');
  end if;
  update public.requests set status = 'cancelled' where id = rq.id;
  update public.offers set status = 'withdrawn' where request_id = rq.id and status = 'pending';
  if rq.match_id is not null then
    update public.match_players set status = 'cancelled' where match_id = rq.match_id;
    update public.matches set status = 'cancelled', cancelled_by = actor, cancel_reason = 'request withdrawn' where id = rq.match_id;
    perform private.emit(mp.user_id, 'match_cancelled', jsonb_build_object('match_id', rq.match_id),
      format('%s withdrew their doubles request.', private.name(actor)))
    from public.match_players mp where mp.match_id = rq.match_id and mp.user_id <> actor;
  end if;
  perform private.emit(i.user_id, 'request_withdrawn', jsonb_build_object('request_id', rq.id),
    format('%s withdrew their invitation.', private.name(actor)))
  from public.request_invitees i where i.request_id = rq.id and i.status = 'invited';
  perform private.log(actor, client, 'cancel_request', rq.id, 'allowed');
  return jsonb_build_object('ok', true, 'status', 'cancelled', 'summary', 'Request withdrawn.');
end;
$$;

-- ---------------------------------------------------------------------------
-- cancel_match
-- ---------------------------------------------------------------------------
create or replace function private.cancel_match(actor uuid, client text, p jsonb, bypass boolean default false)
returns jsonb language plpgsql set search_path = '' as $$
declare
  m public.matches;
  late boolean;
  tz text := private.tz(actor);
  reason text := nullif(p ->> 'reason', '');
begin
  select * into m from public.matches where id = (p ->> 'match_id')::uuid for update;
  if not found or not exists (select 1 from public.match_players where match_id = m.id and user_id = actor and status = 'confirmed') then
    return private.err('not_found', 'You have no live match with that id.', 'Call list_matches for your matches.');
  end if;
  if m.status not in ('forming', 'booked') then
    return private.err('not_live', format('That match is already %s.', m.status));
  end if;
  if m.starts_at <= now() then
    return private.err('already_started', 'That match has already started.', 'Report the score, or tell your opponent in the match chat.');
  end if;
  late := m.status = 'booked' and m.starts_at - now() < interval '12 hours';
  if late and client is not null and not bypass then
    return private.park(actor, client, 'cancel_match', p, array['Cancelling inside 12 hours counts against your reliability'],
      format('cancel your %s on %s', m.format, private.fmt_time(m.starts_at, tz)));
  end if;
  update public.matches set status = 'cancelled', cancelled_by = actor, cancel_reason = reason where id = m.id;
  update public.match_players set status = 'cancelled' where match_id = m.id and status = 'confirmed';
  update public.requests set status = 'cancelled' where id = m.request_id and status = 'open';
  update public.offers set status = 'withdrawn' where request_id = m.request_id and status = 'pending';
  if late then
    update public.profiles set late_cancels = late_cancels + 1 where id = actor;
  end if;
  perform private.emit(mp.user_id, 'match_cancelled', jsonb_build_object('match_id', m.id, 'by', actor),
    format('%s cancelled %s on %s%s.', private.name(actor), m.format, private.fmt_time(m.starts_at, private.tz(mp.user_id)),
      coalesce(' (' || reason || ')', '')))
  from public.match_players mp where mp.match_id = m.id and mp.user_id <> actor;
  perform private.log(actor, client, 'cancel_match', m.id, case when bypass then 'approved' else 'allowed' end, p);
  return jsonb_build_object('ok', true, 'status', 'cancelled', 'late', late,
    'summary', format('Cancelled your %s on %s.%s', m.format, private.fmt_time(m.starts_at, tz),
      case when late then ' Late cancel: it counts against reliability.' else '' end));
end;
$$;

-- ---------------------------------------------------------------------------
-- send_message
-- ---------------------------------------------------------------------------
create or replace function private.send_message(actor uuid, client text, p jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  m_id uuid := nullif(p ->> 'match_id', '')::uuid;
  to_id uuid := nullif(p ->> 'to_player_id', '')::uuid;
  body text := trim(coalesce(p ->> 'text', ''));
  msg_id uuid;
begin
  if body = '' or char_length(body) > 2000 then
    return private.err('bad_text', 'Message text must be 1–2000 characters.');
  end if;
  if (m_id is null) = (to_id is null) then
    return private.err('bad_target', 'Give either match_id or to_player_id.');
  end if;
  if m_id is not null then
    if not exists (select 1 from public.match_players where match_id = m_id and user_id = actor) then
      return private.err('not_found', 'You are not in that match.');
    end if;
  else
    if not ((private.follows(actor, to_id) and private.follows(to_id, actor)) or private.have_played(actor, to_id)) then
      return private.err('not_allowed', 'You can message players you both follow, or have played with.');
    end if;
  end if;
  insert into public.messages (match_id, sender_id, recipient_id, body, created_via)
  values (m_id, actor, to_id, body, case when client is null then 'app' else 'agent' end)
  returning id into msg_id;
  if m_id is not null then
    perform private.emit(mp.user_id, 'message', jsonb_build_object('message_id', msg_id, 'match_id', m_id, 'from', actor),
      format('%s: %s', private.name(actor), left(body, 120)))
    from public.match_players mp where mp.match_id = m_id and mp.user_id <> actor;
  else
    perform private.emit(to_id, 'message', jsonb_build_object('message_id', msg_id, 'from', actor),
      format('%s: %s', private.name(actor), left(body, 120)));
  end if;
  perform private.log(actor, client, 'send_message', msg_id, 'allowed');
  return jsonb_build_object('ok', true, 'status', 'sent', 'message_id', msg_id, 'summary', 'Message sent.');
end;
$$;

-- ---------------------------------------------------------------------------
-- update_availability
-- Agents may add or remove blackouts. Weekly windows widen what agents may
-- book, so an agent changing them needs the player's OK.
-- params: weekly: [{weekday, start, end}] (replaces all), add_blackouts: [{start, end}], remove_blackout_ids: []
-- ---------------------------------------------------------------------------
create or replace function private.update_availability(actor uuid, client text, p jsonb, bypass boolean default false)
returns jsonb language plpgsql set search_path = '' as $$
declare
  w jsonb;
  b jsonb;
begin
  if p ? 'weekly' then
    if client is not null and not bypass then
      return private.park(actor, client, 'update_availability', p, array['Weekly availability sets what your agent may book'],
        'change your weekly availability');
    end if;
    delete from public.availability where user_id = actor and kind = 'weekly';
    for w in select * from jsonb_array_elements(p -> 'weekly') loop
      insert into public.availability (user_id, kind, weekday, start_time, end_time)
      values (actor, 'weekly', (w ->> 'weekday')::smallint, (w ->> 'start')::time, (w ->> 'end')::time);
    end loop;
  end if;
  for b in select * from jsonb_array_elements(coalesce(p -> 'add_blackouts', '[]')) loop
    insert into public.availability (user_id, kind, starts_at, ends_at)
    values (actor, 'blackout', (b ->> 'start')::timestamptz, (b ->> 'end')::timestamptz);
  end loop;
  delete from public.availability
   where user_id = actor and kind = 'blackout'
     and id in (select x::uuid from jsonb_array_elements_text(coalesce(p -> 'remove_blackout_ids', '[]')) x);
  perform private.log(actor, client, 'update_availability', null, case when bypass then 'approved' else 'allowed' end, p);
  return jsonb_build_object('ok', true, 'status', 'updated', 'summary', 'Availability updated.');
exception when others then
  return private.err('bad_availability', 'Availability entries are invalid.',
    'weekly: [{weekday 0-6 (0=Sunday), start "HH:MM", end "HH:MM"}]; add_blackouts: [{start, end}] ISO 8601.');
end;
$$;

-- ---------------------------------------------------------------------------
-- decide_approval (app only): approve runs the parked action as the agent.
-- ---------------------------------------------------------------------------
create or replace function private.decide_approval(actor uuid, client text, p jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare
  a public.approvals;
  res jsonb;
begin
  if client is not null then
    return private.err('app_only', 'Only the player can approve or decline, in the Pickup app.');
  end if;
  select * into a from public.approvals where id = (p ->> 'approval_id')::uuid and user_id = actor for update;
  if not found then
    return private.err('not_found', 'No such approval.');
  end if;
  if a.status <> 'pending' then
    return private.err('already_decided', format('Already %s.', a.status));
  end if;
  if a.expires_at <= now() then
    update public.approvals set status = 'expired' where id = a.id;
    return private.err('expired', 'This approval expired.');
  end if;
  if coalesce(p ->> 'decision', '') = 'decline' then
    update public.approvals set status = 'declined', decided_at = now() where id = a.id;
    perform private.log(actor, null, a.action, a.id, 'declined');
    return jsonb_build_object('ok', true, 'status', 'declined', 'summary', 'Declined. Your agent will see this.');
  end if;
  res := private.dispatch(actor, a.client_id, a.action, a.params, true);
  update public.approvals set status = 'approved', decided_at = now(), result = res where id = a.id;
  return jsonb_build_object('ok', coalesce((res ->> 'ok')::boolean, false), 'status', 'approved', 'result', res,
    'summary', 'Approved. ' || coalesce(res ->> 'summary', res -> 'error' ->> 'message', ''));
end;
$$;

-- ---------------------------------------------------------------------------
-- Reads (agents use these; the app reads tables directly through RLS)
-- ---------------------------------------------------------------------------

create or replace function private.offer_view(o public.offers, viewer uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'offer_id', o.id,
    'request_id', o.request_id,
    'from', jsonb_build_object('player_id', o.from_user, 'name', private.name(o.from_user), 'level', private.level(o.from_user)),
    'format', r.format,
    'mode', r.mode,
    'round', o.round,
    'slots', (select jsonb_agg(jsonb_build_object('slot_index', ord - 1, 'start', s ->> 'start', 'end', s ->> 'end',
                                                  'court_id', s ->> 'court_id', 'court', private.court_name((s ->> 'court_id')::uuid),
                                                  'text', private.slot_text(s, private.tz(viewer))))
              from jsonb_array_elements(o.slots) with ordinality as t(s, ord)),
    'note', case when r.note is not null then jsonb_build_object('untrusted_user_text', r.note) end,
    'expires_at', o.expires_at)
  from public.requests r where r.id = o.request_id
$$;

create or replace function private.match_view(m public.matches, viewer uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'match_id', m.id,
    'format', m.format,
    'status', m.status,
    'start', m.starts_at,
    'end', m.ends_at,
    'when', private.fmt_time(m.starts_at, private.tz(viewer)),
    'court', jsonb_build_object('court_id', m.court_id, 'name', private.court_name(m.court_id)),
    'players', (select jsonb_agg(jsonb_build_object('player_id', mp.user_id, 'name', private.name(mp.user_id), 'team', mp.team) order by mp.team)
                from public.match_players mp where mp.match_id = m.id and mp.status = 'confirmed'))
$$;

create or replace function private.needs_attention(actor uuid, client text, p jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  since bigint := coalesce((p ->> 'since')::bigint, 0);
  res jsonb;
begin
  select jsonb_build_object(
    'ok', true,
    'incoming_offers', coalesce((select jsonb_agg(private.offer_view(o, actor) order by o.created_at)
        from public.offers o where o.to_user = actor and o.status = 'pending' and o.expires_at > now()), '[]'),
    'waiting_on_your_player', coalesce((select jsonb_agg(jsonb_build_object('approval_id', a.id, 'client_id', a.client_id, 'summary', a.summary, 'reasons', a.reasons, 'created_at', a.created_at) order by a.created_at)
        from public.approvals a where a.user_id = actor and a.status = 'pending' and a.expires_at > now()), '[]'),
    'recent_approval_decisions', coalesce((select jsonb_agg(jsonb_build_object('approval_id', a.id, 'status', a.status, 'summary', a.summary,
                                                                              'result_summary', coalesce(a.result ->> 'summary', a.result -> 'error' ->> 'message')))
        from public.approvals a where a.user_id = actor and a.status in ('approved', 'declined') and a.decided_at > now() - interval '3 days'), '[]'),
    'my_open_requests', coalesce((select jsonb_agg(jsonb_build_object('request_id', r.id, 'format', r.format, 'mode', r.mode,
                                   'slots', (select jsonb_agg(private.slot_text(s, private.tz(actor))) from jsonb_array_elements(r.slots) s),
                                   'expires_at', r.expires_at))
        from public.requests r where r.creator_id = actor and r.status = 'open'), '[]'),
    'upcoming_matches', coalesce((select jsonb_agg(private.match_view(m, actor) order by m.starts_at)
        from public.matches m join public.match_players mp on mp.match_id = m.id
        where mp.user_id = actor and mp.status = 'confirmed' and m.status in ('forming', 'booked') and m.starts_at > now()), '[]'),
    'new_events', coalesce((select jsonb_agg(jsonb_build_object('event_id', e.id, 'type', e.type, 'summary', e.summary, 'at', e.created_at) order by e.id)
        from (select * from public.events where user_id = actor and id > since order by id limit 50) e), '[]'),
    'next_since', coalesce((select max(id) from public.events where user_id = actor), since)
  ) into res;
  return res;
end;
$$;

create or replace function private.get_me(actor uuid, client text, p jsonb)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'ok', true,
    'player_id', pr.id,
    'name', pr.display_name,
    'city', pr.city,
    'level', private.level(pr.id),
    'self_level', pr.self_level,
    'rating', case when pr.rated_matches >= 5 then round(pr.rating::numeric, 2) end,
    'rating_status', case when pr.rated_matches >= 5 then 'established' else format('provisional (%s of 5 matches)', pr.rated_matches) end,
    'time_zone', pr.time_zone,
    'connected_as', case when client is null then 'app' else 'agent' end,
    'home_courts', coalesce((select jsonb_agg(jsonb_build_object('court_id', c.id, 'name', c.name) order by h.rank)
        from public.home_courts h join public.courts c on c.id = h.court_id where h.user_id = pr.id), '[]'),
    'weekly_availability', coalesce((select jsonb_agg(jsonb_build_object('weekday', a.weekday, 'start', to_char(a.start_time, 'HH24:MI'), 'end', to_char(a.end_time, 'HH24:MI')) order by a.weekday, a.start_time)
        from public.availability a where a.user_id = pr.id and a.kind = 'weekly'), '[]'),
    'blackouts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'start', a.starts_at, 'end', a.ends_at) order by a.starts_at)
        from public.availability a where a.user_id = pr.id and a.kind = 'blackout' and a.ends_at > now()), '[]'),
    'agent_rules', (select to_jsonb(r) - 'user_id' - 'updated_at' from public.agent_rules r where r.user_id = pr.id))
  from public.profiles pr where pr.id = actor
$$;

create or replace function private.find_courts(actor uuid, client text, p jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  q text := nullif(trim(coalesce(p ->> 'query', '')), '');
  qlat double precision := coalesce((p ->> 'lat')::double precision, private.home_lat(actor));
  qlng double precision := coalesce((p ->> 'lng')::double precision, private.home_lng(actor));
  lim int := least(coalesce((p ->> 'limit')::int, 10), 50);
begin
  return jsonb_build_object('ok', true, 'courts', coalesce((
    select jsonb_agg(x.j order by x.home desc, x.d nulls last, x.name)
    from (
      select c.name,
             exists (select 1 from public.home_courts h where h.user_id = actor and h.court_id = c.id) as home,
             private.miles(qlat, qlng, c.lat, c.lng) as d,
             jsonb_strip_nulls(jsonb_build_object('court_id', c.id, 'name', c.name, 'address', c.address,
               'public', c.is_public, 'courts', c.court_count, 'setting', c.setting, 'hours', c.hours,
               'home_court', exists (select 1 from public.home_courts h where h.user_id = actor and h.court_id = c.id),
               'miles_away', round(private.miles(qlat, qlng, c.lat, c.lng)::numeric, 1))) as j
      from public.courts c
      where 'tennis' = any (c.sports)
        and (q is null or c.name ilike '%' || q || '%' or c.address ilike '%' || q || '%')
      order by exists (select 1 from public.home_courts h where h.user_id = actor and h.court_id = c.id) desc,
               private.miles(qlat, qlng, c.lat, c.lng) nulls last, c.name
      limit lim
    ) x), '[]'));
end;
$$;

create or replace function private.find_players(actor uuid, client text, p jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  my_level numeric := private.level(actor);
  lmin numeric := coalesce((p ->> 'level_min')::numeric, my_level - 0.5, 1.0);
  lmax numeric := coalesce((p ->> 'level_max')::numeric, my_level + 0.5, 7.0);
  q text := nullif(trim(coalesce(p ->> 'name', '')), '');
  near uuid := nullif(p ->> 'near_court_id', '')::uuid;
  lat double precision := coalesce((select c.lat from public.courts c where c.id = near), private.home_lat(actor));
  lng double precision := coalesce((select c.lng from public.courts c where c.id = near), private.home_lng(actor));
  radius double precision := coalesce((p ->> 'within_miles')::double precision, 10);
  at_ts timestamptz := nullif(p ->> 'available_at', '')::timestamptz;
  following_only boolean := coalesce((p ->> 'following_only')::boolean, false);
  lim int := least(coalesce((p ->> 'limit')::int, 10), 30);
begin
  return jsonb_build_object('ok', true, 'players', coalesce((
    select jsonb_agg(x.card order by x.score desc)
    from (
      select
        jsonb_strip_nulls(jsonb_build_object(
          'player_id', pr.id,
          'name', pr.display_name,
          'city', pr.city,
          'level', private.level(pr.id),
          'rating_status', case when pr.rated_matches >= 5 then 'established' else 'provisional' end,
          'reliability_pct', case when pr.matches_booked >= 3 then round(100.0 * pr.matches_kept / pr.matches_booked) end,
          'miles_away', round(private.miles(lat, lng, pr.area_lat::double precision, pr.area_lng::double precision)::numeric, 1),
          'you_follow', private.follows(actor, pr.id),
          'played_before', private.have_played(actor, pr.id),
          'free_then', case when at_ts is null then null else exists (
              select 1 from public.availability a where a.user_id = pr.id and a.kind = 'weekly'
                and a.weekday = extract(dow from at_ts at time zone pr.time_zone)::int
                and (at_ts at time zone pr.time_zone)::time between a.start_time and a.end_time) end)) as card,
        (case when private.follows(actor, pr.id) then 2 else 0 end)
          + (case when private.have_played(actor, pr.id) then 1 else 0 end)
          - coalesce(abs(private.level(pr.id) - my_level), 1) * 2
          - coalesce(private.miles(lat, lng, pr.area_lat::double precision, pr.area_lng::double precision), radius) / 10.0
          + coalesce(case when pr.matches_booked >= 3 then pr.matches_kept::numeric / pr.matches_booked end, 0.8) as score
      from public.profiles pr
      where pr.id <> actor
        and pr.onboarded
        and (pr.visibility = 'public' or private.follows(actor, pr.id))
        and (q is null or pr.display_name ilike '%' || q || '%')
        and (q is not null or private.level(pr.id) is null or private.level(pr.id) between lmin and lmax)
        and (not following_only or private.follows(actor, pr.id))
        and (q is not null or private.miles(lat, lng, pr.area_lat::double precision, pr.area_lng::double precision) is null
             or private.miles(lat, lng, pr.area_lat::double precision, pr.area_lng::double precision) <= radius)
      order by score desc
      limit lim
    ) x), '[]'));
end;
$$;

create or replace function private.find_open_games(actor uuid, client text, p jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  my_level numeric := private.level(actor);
  radius double precision := coalesce((p ->> 'within_miles')::double precision, 15);
  hl double precision := private.home_lat(actor);
  hg double precision := private.home_lng(actor);
begin
  return jsonb_build_object('ok', true, 'games', coalesce((
    select jsonb_agg(private.offer_view(o, actor) || jsonb_build_object('spots_left',
             case when r.format = 'doubles' then 4 - (select count(*) from public.match_players where match_id = r.match_id and status = 'confirmed') else 1 end)
           order by o.expires_at)
    from public.offers o join public.requests r on r.id = o.request_id
    where o.to_user is null and o.status = 'pending' and r.status = 'open' and r.creator_id <> actor
      and o.expires_at > now()
      and (my_level is null or r.level_min is null or my_level between r.level_min and r.level_max)
      and (p ->> 'format' is null or r.format = p ->> 'format')
      and not exists (select 1 from public.match_players mp where mp.match_id = r.match_id and mp.user_id = actor)
      and exists (select 1 from jsonb_array_elements(o.slots) s join public.courts c on c.id = (s ->> 'court_id')::uuid
                  where coalesce(private.miles(hl, hg, c.lat, c.lng), 0) <= radius)
  ), '[]'));
end;
$$;

create or replace function private.list_matches(actor uuid, client text, p jsonb)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('ok', true, 'matches', coalesce((
    select jsonb_agg(private.match_view(m, actor) order by
             case when coalesce(p ->> 'when', 'upcoming') = 'past' then -extract(epoch from m.starts_at) else extract(epoch from m.starts_at) end)
    from public.matches m join public.match_players mp on mp.match_id = m.id
    where mp.user_id = actor
      and case coalesce(p ->> 'when', 'upcoming')
            when 'past' then m.starts_at <= now() or m.status in ('completed', 'cancelled')
            else m.starts_at > now() and m.status in ('forming', 'booked') and mp.status = 'confirmed' end
    ), '[]'))
$$;

-- ---------------------------------------------------------------------------
-- Dispatcher: the single entry point.
-- ---------------------------------------------------------------------------
create or replace function private.dispatch(actor uuid, client text, action text, p jsonb, bypass boolean default false)
returns jsonb language plpgsql set search_path = '' as $$
begin
  return case action
    when 'request_match'       then private.request_match(actor, client, p, bypass)
    when 'respond_to_offer'    then private.respond_to_offer(actor, client, p, bypass)
    when 'cancel_request'      then private.cancel_request(actor, client, p)
    when 'cancel_match'        then private.cancel_match(actor, client, p, bypass)
    when 'send_message'        then private.send_message(actor, client, p)
    when 'update_availability' then private.update_availability(actor, client, p, bypass)
    when 'decide_approval'     then private.decide_approval(actor, client, p)
    when 'needs_attention'     then private.needs_attention(actor, client, p)
    when 'get_me'              then private.get_me(actor, client, p)
    when 'find_courts'         then private.find_courts(actor, client, p)
    when 'find_players'        then private.find_players(actor, client, p)
    when 'find_open_games'     then private.find_open_games(actor, client, p)
    when 'list_matches'        then private.list_matches(actor, client, p)
    else private.err('unknown_action', format('Unknown action %s.', action))
  end;
end;
$$;

create or replace function private.call(actor uuid, client text, action text, p jsonb, idem_key text default null)
returns jsonb language plpgsql set search_path = '' as $$
declare
  res jsonb;
begin
  if actor is null or not exists (select 1 from public.profiles where id = actor) then
    return private.err('not_signed_in', 'No Pickup player for this sign-in.');
  end if;
  if idem_key is not null then
    select result into res from private.idempotency where user_id = actor and key = idem_key;
    if found then
      return res || jsonb_build_object('replayed', true);
    end if;
  end if;
  begin
    res := private.dispatch(actor, client, action, coalesce(p, '{}'), false);
  exception
    when sqlstate 'PK001' then
      res := private.err('time_conflict', sqlerrm, 'Pick a time when you are free.');
    when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
      res := private.err('bad_input', 'An id or time in the request is malformed.', 'Ids are UUIDs; times are ISO 8601 with an offset.');
  end;
  if idem_key is not null and coalesce((res ->> 'ok')::boolean, false) then
    insert into private.idempotency (user_id, key, action, result) values (actor, idem_key, action, res)
    on conflict do nothing;
  end if;
  return res;
end;
$$;

-- ---------------------------------------------------------------------------
-- Housekeeping, run every few minutes by pg_cron.
-- ---------------------------------------------------------------------------
create or replace function private.expire_stale()
returns void language plpgsql set search_path = '' as $$
declare
  r record;
begin
  for r in select * from public.requests where status = 'open' and expires_at <= now() for update loop
    update public.requests set status = 'expired' where id = r.id;
    update public.offers set status = 'expired' where request_id = r.id and status = 'pending';
    if r.match_id is not null then
      update public.match_players set status = 'cancelled' where match_id = r.match_id and status = 'confirmed';
      update public.matches set status = 'cancelled', cancel_reason = 'not enough players' where id = r.match_id and status = 'forming';
    end if;
    perform private.emit(r.creator_id, 'request_expired', jsonb_build_object('request_id', r.id),
      'Your request expired before anyone took it.');
  end loop;
  update public.offers set status = 'expired' where status = 'pending' and expires_at <= now();
  update public.approvals set status = 'expired' where status = 'pending' and expires_at <= now();
  delete from private.idempotency where created_at < now() - interval '7 days';
end;
$$;

revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.is_match_player(uuid) to authenticated;
revoke all on all tables in schema private from public, anon, authenticated;
