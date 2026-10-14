-- Pickup v2 — core schema
-- Every table has row-level security. Clients read through RLS and change
-- state only through the functions in the next migration (or, for a few
-- self-owned tables, direct writes limited to their own rows).

create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- The OAuth client (agent) behind the current request, or null for the app.
create or replace function public.current_client_id()
returns text
language sql stable
set search_path = ''
as $$
  select nullif(auth.jwt() ->> 'client_id', '')
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Players
-- ---------------------------------------------------------------------------

create table public.profiles (
  id                uuid primary key references auth.users (id) on delete cascade,
  display_name      text not null default '' check (char_length(display_name) <= 60),
  photo_url         text,
  city              text,
  -- Home AREA only: rounded to ~1 km. Exact location lives in private_details.
  area_lat          numeric(6,2),
  area_lng          numeric(6,2),
  self_level        numeric(2,1) check (self_level between 1.0 and 7.0),
  rating            double precision,          -- Pickup Rating on the NTRP scale
  rating_rd         double precision,          -- Glicko-2 rating deviation (NTRP units)
  rating_vol        double precision,          -- Glicko-2 volatility
  rated_matches     integer not null default 0,
  matches_booked    integer not null default 0,
  matches_kept      integer not null default 0,
  late_cancels      integer not null default 0,
  no_shows          integer not null default 0,
  visibility        text not null default 'public' check (visibility in ('public', 'private')),
  time_zone         text not null default 'America/New_York',
  onboarded         boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table public.private_details (
  user_id           uuid primary key references public.profiles (id) on delete cascade,
  email             text,
  phone             text,
  birthday          date,
  gender            text check (gender in ('male', 'female', 'other')),
  home_lat          double precision,
  home_lng          double precision,
  is_adult          boolean not null default false,
  updated_at        timestamptz not null default now()
);

create table public.courts (
  id                uuid primary key default gen_random_uuid(),
  name              text not null,
  address           text,
  city              text,
  state             text,
  zip               text,
  lat               double precision not null,
  lng               double precision not null,
  is_public         boolean not null default true,
  setting           text,                      -- outdoor, indoor, outdoor/indoor
  surface           text,
  court_count       integer,
  has_lights        boolean,
  reservation_required boolean,
  hours             text,
  phone             text,
  website           text,
  sports            text[] not null default '{tennis}',
  created_at        timestamptz not null default now()
);

create table public.home_courts (
  user_id           uuid not null references public.profiles (id) on delete cascade,
  court_id          uuid not null references public.courts (id) on delete cascade,
  rank              smallint not null default 1,
  primary key (user_id, court_id)
);

-- Weekly windows (kind = weekly) and one-off blackouts (kind = blackout).
create table public.availability (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  kind              text not null check (kind in ('weekly', 'blackout')),
  weekday           smallint check (weekday between 0 and 6),      -- 0 = Sunday
  start_time        time,
  end_time          time,
  starts_at         timestamptz,
  ends_at           timestamptz,
  constraint availability_shape check (
    (kind = 'weekly' and weekday is not null and start_time is not null and end_time is not null and start_time < end_time and starts_at is null and ends_at is null)
    or
    (kind = 'blackout' and starts_at is not null and ends_at is not null and starts_at < ends_at and weekday is null and start_time is null and end_time is null)
  )
);

-- What a player's agents may do without asking. Agents can never edit this.
create table public.agent_rules (
  user_id           uuid primary key references public.profiles (id) on delete cascade,
  autonomy          text not null default 'auto' check (autonomy in ('ask', 'auto')),
  within_availability boolean not null default true,
  home_courts_or_miles numeric(4,1) not null default 5.0 check (home_courts_or_miles between 0 and 50),
  formats           text[] not null default '{singles,doubles}',
  opponents         text not null default 'anyone' check (opponents in ('anyone', 'following', 'list')),
  allow_list        uuid[] not null default '{}',
  level_band        numeric(2,1) not null default 0.5 check (level_band between 0 and 3),
  max_per_week      smallint not null default 3 check (max_per_week between 0 and 21),
  min_notice_hours  smallint not null default 4 check (min_notice_hours between 0 and 168),
  new_opponent_needs_ok boolean not null default true,
  updated_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Requests, offers, matches
-- ---------------------------------------------------------------------------

create table public.requests (
  id                uuid primary key default gen_random_uuid(),
  creator_id        uuid not null references public.profiles (id) on delete cascade,
  sport             text not null default 'tennis',
  format            text not null check (format in ('singles', 'doubles')),
  mode              text not null check (mode in ('direct', 'open')),
  partner_id        uuid references public.profiles (id),   -- doubles: creator's partner, optional
  level_min         numeric(2,1),
  level_max         numeric(2,1),
  -- Singles: candidate slots the creator can do. Doubles: exactly one slot.
  -- [{ "start": iso, "end": iso, "court_id": uuid }]
  slots             jsonb not null default '[]',
  note              text check (char_length(note) <= 500),
  status            text not null default 'open'
                    check (status in ('pending_approval', 'open', 'booked', 'expired', 'cancelled')),
  expires_at        timestamptz not null,
  match_id          uuid,
  created_via       text not null default 'app' check (created_via in ('app', 'agent')),
  client_id         text,
  created_at        timestamptz not null default now()
);

create table public.request_invitees (
  request_id        uuid not null references public.requests (id) on delete cascade,
  user_id           uuid not null references public.profiles (id) on delete cascade,
  status            text not null default 'invited' check (status in ('invited', 'declined', 'accepted')),
  updated_at        timestamptz not null default now(),
  primary key (request_id, user_id)
);

create table public.offers (
  id                uuid primary key default gen_random_uuid(),
  request_id        uuid not null references public.requests (id) on delete cascade,
  from_user         uuid not null references public.profiles (id) on delete cascade,
  to_user           uuid references public.profiles (id) on delete cascade,   -- null = anyone eligible (open request)
  slots             jsonb not null,
  status            text not null default 'pending'
                    check (status in ('pending', 'accepted', 'countered', 'declined', 'withdrawn', 'expired')),
  parent_offer_id   uuid references public.offers (id),
  round             smallint not null default 1,
  accepted_slot     smallint,
  accepted_by       uuid references public.profiles (id),
  expires_at        timestamptz not null,
  created_via       text not null default 'app' check (created_via in ('app', 'agent')),
  client_id         text,
  created_at        timestamptz not null default now(),
  responded_at      timestamptz
);

create table public.matches (
  id                uuid primary key default gen_random_uuid(),
  request_id        uuid references public.requests (id) on delete set null,
  sport             text not null default 'tennis',
  format            text not null check (format in ('singles', 'doubles')),
  starts_at         timestamptz not null,
  ends_at           timestamptz not null,
  court_id          uuid references public.courts (id),
  status            text not null default 'booked'
                    check (status in ('forming', 'booked', 'completed', 'cancelled')),
  cancelled_by      uuid references public.profiles (id),
  cancel_reason     text,
  reminded_day      boolean not null default false,
  reminded_soon     boolean not null default false,
  created_at        timestamptz not null default now(),
  check (starts_at < ends_at)
);

alter table public.requests
  add constraint requests_match_fk foreign key (match_id) references public.matches (id) on delete set null;

create table public.match_players (
  match_id          uuid not null references public.matches (id) on delete cascade,
  user_id           uuid not null references public.profiles (id) on delete cascade,
  team              smallint not null check (team in (1, 2)),
  status            text not null default 'confirmed' check (status in ('confirmed', 'cancelled', 'no_show')),
  during            tstzrange not null,
  primary key (match_id, user_id),
  -- No player can hold two live matches whose times overlap.
  constraint no_double_booking exclude using gist (user_id with =, during with &&)
    where (status = 'confirmed')
);

create table public.results (
  match_id          uuid primary key references public.matches (id) on delete cascade,
  sets              jsonb not null,          -- [[6,4],[3,6],[10,8]] from team 1's side
  winner_team       smallint not null check (winner_team in (1, 2)),
  reported_by       uuid not null references public.profiles (id),
  confirmed_by      uuid references public.profiles (id),
  status            text not null default 'reported' check (status in ('reported', 'confirmed', 'disputed')),
  dispute_note      text,
  reported_at       timestamptz not null default now(),
  confirmed_at      timestamptz,
  auto_confirm_at   timestamptz not null
);

create table public.rating_history (
  id                bigint generated always as identity primary key,
  user_id           uuid not null references public.profiles (id) on delete cascade,
  match_id          uuid not null references public.matches (id) on delete cascade,
  rating_before     double precision not null,
  rating_after      double precision not null,
  rd_before         double precision not null,
  rd_after          double precision not null,
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Social, approvals, events, audit
-- ---------------------------------------------------------------------------

create table public.follows (
  follower_id       uuid not null references public.profiles (id) on delete cascade,
  followee_id       uuid not null references public.profiles (id) on delete cascade,
  status            text not null default 'accepted' check (status in ('pending', 'accepted')),
  created_at        timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);

create table public.messages (
  id                uuid primary key default gen_random_uuid(),
  match_id          uuid references public.matches (id) on delete cascade,
  sender_id         uuid not null references public.profiles (id) on delete cascade,
  recipient_id      uuid references public.profiles (id) on delete cascade,
  body              text not null check (char_length(body) between 1 and 2000),
  created_via       text not null default 'app' check (created_via in ('app', 'agent')),
  created_at        timestamptz not null default now(),
  check ((match_id is null) <> (recipient_id is null))
);

create table public.approvals (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  client_id         text,
  action            text not null,
  params            jsonb not null,
  reasons           text[] not null default '{}',
  summary           text not null,
  status            text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'expired')),
  result            jsonb,
  created_at        timestamptz not null default now(),
  decided_at        timestamptz,
  expires_at        timestamptz not null default now() + interval '48 hours'
);

create table public.events (
  id                bigint generated always as identity primary key,
  user_id           uuid not null references public.profiles (id) on delete cascade,
  type              text not null,
  payload           jsonb not null default '{}',
  summary           text not null,
  created_at        timestamptz not null default now(),
  read_at           timestamptz,
  pushed_at         timestamptz
);

create table public.activity_log (
  id                bigint generated always as identity primary key,
  user_id           uuid references public.profiles (id) on delete cascade,
  actor             text not null check (actor in ('app', 'agent', 'system')),
  client_id         text,
  action            text not null,
  target_id         uuid,
  decision          text,          -- allowed, needs_approval, approved, declined
  detail            jsonb not null default '{}',
  created_at        timestamptz not null default now()
);

create table public.api_keys (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  name              text not null,
  prefix            text not null,
  key_hash          text not null unique,
  created_at        timestamptz not null default now(),
  last_used_at      timestamptz,
  revoked_at        timestamptz
);

create table public.push_subscriptions (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  endpoint          text not null unique,
  p256dh            text not null,
  auth              text not null,
  created_at        timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

create index on public.home_courts (court_id);
create index on public.availability (user_id);
create index on public.requests (creator_id);
create index on public.requests (status, expires_at);
create index on public.requests (partner_id);
create index on public.requests (match_id);
create index on public.request_invitees (user_id);
create index on public.offers (request_id);
create index on public.offers (to_user, status);
create index on public.offers (from_user);
create index on public.offers (parent_offer_id);
create index on public.offers (accepted_by);
create index on public.matches (request_id);
create index on public.matches (court_id);
create index on public.matches (status, starts_at);
create index on public.matches (cancelled_by);
create index on public.match_players (user_id);
create index on public.results (reported_by);
create index on public.results (confirmed_by);
create index on public.results (status, auto_confirm_at);
create index on public.rating_history (user_id);
create index on public.rating_history (match_id);
create index on public.follows (followee_id);
create index on public.messages (match_id, created_at);
create index on public.messages (sender_id);
create index on public.messages (recipient_id);
create index on public.approvals (user_id, status);
create index on public.events (user_id, id);
create index on public.activity_log (user_id, id);
create index on public.api_keys (user_id);
create index on public.push_subscriptions (user_id);

-- ---------------------------------------------------------------------------
-- updated_at triggers
-- ---------------------------------------------------------------------------

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger private_details_touch before update on public.private_details
  for each row execute function public.touch_updated_at();
create trigger agent_rules_touch before update on public.agent_rules
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- New users get a profile, private row and default agent rules.
-- ---------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, photo_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', split_part(coalesce(new.email, ''), '@', 1), ''),
    new.raw_user_meta_data ->> 'avatar_url'
  );
  insert into public.private_details (user_id, email) values (new.id, new.email);
  insert into public.agent_rules (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------

alter table public.profiles           enable row level security;
alter table public.private_details    enable row level security;
alter table public.courts             enable row level security;
alter table public.home_courts        enable row level security;
alter table public.availability       enable row level security;
alter table public.agent_rules        enable row level security;
alter table public.requests           enable row level security;
alter table public.request_invitees   enable row level security;
alter table public.offers             enable row level security;
alter table public.matches            enable row level security;
alter table public.match_players      enable row level security;
alter table public.results            enable row level security;
alter table public.rating_history     enable row level security;
alter table public.follows            enable row level security;
alter table public.messages           enable row level security;
alter table public.approvals          enable row level security;
alter table public.events             enable row level security;
alter table public.activity_log       enable row level security;
alter table public.api_keys           enable row level security;
alter table public.push_subscriptions enable row level security;

-- Is the signed-in player one of this match's players?
create or replace function public.is_match_player(m uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.match_players mp
    where mp.match_id = m and mp.user_id = (select auth.uid())
  )
$$;

-- profiles: any signed-in player sees public cards; private cards only to
-- the owner and to people they've accepted as followers.
create policy profiles_read on public.profiles for select to authenticated
  using (
    visibility = 'public'
    or id = (select auth.uid())
    or exists (select 1 from public.follows f
               where f.followee_id = profiles.id and f.follower_id = (select auth.uid()) and f.status = 'accepted')
  );
-- Owners edit their own card through the app only (not agents); the
-- counters and rating columns are protected by a trigger below.
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = (select auth.uid()) and public.current_client_id() is null)
  with check (id = (select auth.uid()) and public.current_client_id() is null);

create policy private_details_self on public.private_details for select to authenticated
  using (user_id = (select auth.uid()));
create policy private_details_update_self on public.private_details for update to authenticated
  using (user_id = (select auth.uid()) and public.current_client_id() is null)
  with check (user_id = (select auth.uid()) and public.current_client_id() is null);

create policy courts_read on public.courts for select to anon, authenticated using (true);

create policy home_courts_read on public.home_courts for select to authenticated
  using (user_id = (select auth.uid()));
create policy home_courts_write on public.home_courts for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy availability_read on public.availability for select to authenticated
  using (user_id = (select auth.uid()));
create policy availability_write on public.availability for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy agent_rules_read on public.agent_rules for select to authenticated
  using (user_id = (select auth.uid()));
create policy agent_rules_update_app_only on public.agent_rules for update to authenticated
  using (user_id = (select auth.uid()) and public.current_client_id() is null)
  with check (user_id = (select auth.uid()) and public.current_client_id() is null);

create policy requests_read on public.requests for select to authenticated
  using (
    creator_id = (select auth.uid())
    or partner_id = (select auth.uid())
    or exists (select 1 from public.request_invitees i where i.request_id = requests.id and i.user_id = (select auth.uid()))
    or (mode = 'open' and status = 'open')
  );

create policy request_invitees_read on public.request_invitees for select to authenticated
  using (
    user_id = (select auth.uid())
    or exists (select 1 from public.requests r where r.id = request_invitees.request_id and r.creator_id = (select auth.uid()))
  );

create policy offers_read on public.offers for select to authenticated
  using (
    from_user = (select auth.uid())
    or to_user = (select auth.uid())
    or (to_user is null and exists (select 1 from public.requests r where r.id = offers.request_id and r.mode = 'open' and r.status = 'open'))
  );

create policy matches_read on public.matches for select to authenticated
  using (public.is_match_player(id));

create policy match_players_read on public.match_players for select to authenticated
  using (public.is_match_player(match_id));

create policy results_read on public.results for select to authenticated
  using (public.is_match_player(match_id));

create policy rating_history_read on public.rating_history for select to authenticated
  using (user_id = (select auth.uid()));

create policy follows_read on public.follows for select to authenticated
  using (follower_id = (select auth.uid()) or followee_id = (select auth.uid()));

create policy messages_read on public.messages for select to authenticated
  using (
    sender_id = (select auth.uid())
    or recipient_id = (select auth.uid())
    or (match_id is not null and public.is_match_player(match_id))
  );

create policy approvals_read on public.approvals for select to authenticated
  using (user_id = (select auth.uid()));

create policy events_read on public.events for select to authenticated
  using (user_id = (select auth.uid()));
create policy events_mark_read on public.events for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy activity_log_read on public.activity_log for select to authenticated
  using (user_id = (select auth.uid()));

create policy api_keys_read on public.api_keys for select to authenticated
  using (user_id = (select auth.uid()) and public.current_client_id() is null);

create policy push_subscriptions_self on public.push_subscriptions for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- Players may not edit their own rating, reliability counters or onboarding
-- bookkeeping directly; only server functions (running as the table owner)
-- change those.
create or replace function public.protect_profile_columns()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('authenticated', 'anon') then
    new.rating         := old.rating;
    new.rating_rd      := old.rating_rd;
    new.rating_vol     := old.rating_vol;
    new.rated_matches  := old.rated_matches;
    new.matches_booked := old.matches_booked;
    new.matches_kept   := old.matches_kept;
    new.late_cancels   := old.late_cancels;
    new.no_shows       := old.no_shows;
    new.id             := old.id;
    new.created_at     := old.created_at;
  end if;
  return new;
end;
$$;

create trigger profiles_protect before update on public.profiles
  for each row execute function public.protect_profile_columns();

-- Column-level limits on what clients may write directly.
revoke update on public.profiles from authenticated, anon;
grant update (display_name, photo_url, city, area_lat, area_lng, self_level, visibility, time_zone, onboarded)
  on public.profiles to authenticated;
revoke update on public.events from authenticated, anon;
grant update (read_at) on public.events to authenticated;

-- Public player card: what other players (and their agents) may see.
create or replace view public.player_cards
with (security_invoker = true)
as
select
  p.id,
  p.display_name,
  p.photo_url,
  p.city,
  p.area_lat,
  p.area_lng,
  p.self_level,
  case when p.rated_matches >= 5 then round(p.rating::numeric, 2) end as rating,
  p.rated_matches,
  case when p.matches_booked >= 3
       then round(100.0 * p.matches_kept / nullif(p.matches_booked, 0))
  end as reliability_pct,
  p.matches_booked,
  p.visibility
from public.profiles p;
