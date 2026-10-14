-- Server-only logic lives in a schema the public API does not expose.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.is_match_player(m uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.match_players mp
    where mp.match_id = m and mp.user_id = (select auth.uid())
  )
$$;
revoke all on function private.is_match_player(uuid) from public, anon;
grant execute on function private.is_match_player(uuid) to authenticated;

alter policy matches_read on public.matches using (private.is_match_player(id));
alter policy match_players_read on public.match_players using (private.is_match_player(match_id));
alter policy results_read on public.results using (private.is_match_player(match_id));
alter policy messages_read on public.messages using (
  sender_id = (select auth.uid())
  or recipient_id = (select auth.uid())
  or (match_id is not null and private.is_match_player(match_id))
);

create or replace function private.handle_new_user()
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
revoke all on function private.handle_new_user() from public, anon, authenticated;

create or replace trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- The old public copies are no longer used; make them uncallable.
revoke all on function public.is_match_player(uuid) from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- Split "for all" write policies so reads are covered by exactly one policy.
create policy home_courts_insert on public.home_courts for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy home_courts_update on public.home_courts for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy home_courts_delete on public.home_courts for delete to authenticated
  using (user_id = (select auth.uid()));
create policy availability_insert on public.availability for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy availability_update on public.availability for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy availability_delete on public.availability for delete to authenticated
  using (user_id = (select auth.uid()));
alter policy home_courts_write on public.home_courts to service_role;
alter policy availability_write on public.availability to service_role;
