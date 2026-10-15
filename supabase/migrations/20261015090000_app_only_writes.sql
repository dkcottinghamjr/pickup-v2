-- Home courts and weekly availability decide what agents may book, so only
-- the player's own app session (no OAuth client_id) may write them directly.
-- Agents change availability through update_availability, which parks
-- weekly changes for the player's OK.
alter policy home_courts_insert on public.home_courts
  with check (user_id = (select auth.uid()) and public.current_client_id() is null);
alter policy home_courts_update on public.home_courts
  using (user_id = (select auth.uid()) and public.current_client_id() is null)
  with check (user_id = (select auth.uid()) and public.current_client_id() is null);
alter policy home_courts_delete on public.home_courts
  using (user_id = (select auth.uid()) and public.current_client_id() is null);
alter policy availability_insert on public.availability
  with check (user_id = (select auth.uid()) and public.current_client_id() is null);
alter policy availability_update on public.availability
  using (user_id = (select auth.uid()) and public.current_client_id() is null)
  with check (user_id = (select auth.uid()) and public.current_client_id() is null);
alter policy availability_delete on public.availability
  using (user_id = (select auth.uid()) and public.current_client_id() is null);
alter policy push_subscriptions_self on public.push_subscriptions
  using (user_id = (select auth.uid()) and public.current_client_id() is null)
  with check (user_id = (select auth.uid()) and public.current_client_id() is null);
