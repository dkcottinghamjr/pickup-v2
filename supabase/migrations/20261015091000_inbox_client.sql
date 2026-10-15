-- needs_attention: say which agent asked for each pending approval.
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

revoke all on function private.needs_attention(uuid, text, jsonb) from public, anon, authenticated;
