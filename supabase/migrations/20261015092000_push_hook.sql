-- Push notifications: each new event for a player with a registered device
-- calls the push Edge Function through pg_net (asynchronous, never blocks the
-- booking). The function URL and shared secret live in Supabase Vault as
-- 'pickup_push_url' and 'pickup_push_secret'.
-- (Skipped by the local test runner, which has no pg_net or Vault.)
create extension if not exists pg_net with schema extensions;

create or replace function private.push_hook()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  url text;
  secret text;
begin
  if not exists (select 1 from public.push_subscriptions where user_id = new.user_id) then
    return new;
  end if;
  select decrypted_secret into url from vault.decrypted_secrets where name = 'pickup_push_url';
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'pickup_push_secret';
  if url is null or secret is null then
    return new;
  end if;
  perform net.http_post(
    url := url,
    body := jsonb_build_object('event_id', new.id),
    headers := jsonb_build_object('content-type', 'application/json', 'x-pickup-hook', secret),
    timeout_milliseconds := 5000);
  return new;
exception when others then
  return new; -- a push problem must never block the action that caused it
end;
$$;
revoke all on function private.push_hook() from public, anon, authenticated;

create or replace trigger events_push after insert on public.events
  for each row execute function private.push_hook();
