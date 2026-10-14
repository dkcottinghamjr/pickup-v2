-- find_courts: rename lat/lng variables that clashed with courts.lat/lng.
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

revoke all on function private.find_courts(uuid, text, jsonb) from public, anon, authenticated;
