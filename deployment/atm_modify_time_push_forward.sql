set local lock_timeout='3s';
CREATE OR REPLACE FUNCTION public.atm_set_task_deadline(p_work_id uuid, p_due_at timestamp with time zone, p_expected_due_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w public.atm_work_items%rowtype; t timestamptz;
begin
 if auth.uid() is null or not public.atm_is_admin() then
   raise exception 'Sin permiso' using errcode='42501';
 end if;
 select * into w from public.atm_work_items where id=p_work_id for update;
 if not found or w.assigned_to is null then raise exception 'Tarea no disponible'; end if;
 t:=clock_timestamp();
 if w.atm_due_at is distinct from p_expected_due_at then
   raise exception 'El plazo cambió. Actualizá la tarea.' using errcode='40001';
 end if;
 if p_due_at is null or not isfinite(p_due_at) then
   raise exception 'Seleccioná una fecha y hora válidas';
 end if;
 -- Explicit admin change starts a newly configured interval. A reduction is not a token grant.
 update public.atm_work_items set atm_due_at=p_due_at,
  atm_window_started_at=least(t,p_due_at-interval '1 second'),
  atm_paused_at=case when w.atm_paused_at is not null and p_due_at>t then t else null end,
  atm_tokens_remaining=case when w.atm_due_at is null then 2
    when p_due_at>(case when w.atm_paused_at is not null then w.atm_due_at+(t-w.atm_paused_at) else w.atm_due_at end) then 2
    else coalesce(w.atm_tokens_remaining,2) end
 where id=w.id returning * into w;
 return jsonb_build_object('id',w.id,'due_at',w.atm_due_at,'started_at',w.atm_window_started_at,'tokens',w.atm_tokens_remaining,'paused_at',w.atm_paused_at,'server_now',t);

end; $function$
;

-- Durable, private, event-driven completion notification outbox.
create extension if not exists pg_net;
create schema if not exists atm_completion_private;
revoke all on schema atm_completion_private from public,anon,authenticated;
create table atm_completion_private.queue(
 event_id uuid primary key references public.atm_calendar_changes(id) on delete cascade,
 token uuid not null default gen_random_uuid(),
 attempts integer not null default 0,
 next_attempt timestamptz not null default clock_timestamp(),
 lease_until timestamptz,
 request_id bigint,
 sent_subscriptions uuid[] not null default '{}'::uuid[],
 done boolean not null default false,
 created_at timestamptz not null default clock_timestamp()
);
alter table atm_completion_private.queue enable row level security;
revoke all on atm_completion_private.queue from public,anon,authenticated;
-- pg_net was not installed previously; protect queue bodies containing per-event tokens.
revoke all on schema net from public,anon,authenticated;
revoke all on all tables in schema net from public,anon,authenticated;
revoke execute on all functions in schema net from public,anon,authenticated;
create function atm_completion_private.dispatch(p_event uuid) returns void
language plpgsql security definer set search_path='' as $$
declare q atm_completion_private.queue%rowtype; request bigint;
begin
 select * into q from atm_completion_private.queue where event_id=p_event and not done and attempts<8 and next_attempt<=clock_timestamp() and (lease_until is null or lease_until<=clock_timestamp()) for update skip locked;
 if not found then return;end if;
 -- Increment even if the asynchronous network request fails. Retry only pending events.
 update atm_completion_private.queue set attempts=attempts+1,next_attempt=clock_timestamp()+interval '5 minutes' where event_id=q.event_id;
 begin
  request:=net.http_post(url:='https://mnwqvzhjkkoxcjxdolac.supabase.co/functions/v1/atm-push',
   body:=jsonb_build_object('action','completion-worker','event_id',q.event_id,'token',q.token),timeout_milliseconds:=30000);
  update atm_completion_private.queue set request_id=request where event_id=q.event_id;
 exception when others then
  -- A transport failure must not undo the employee's completion.
  null;
 end;
end $$;
revoke all on function atm_completion_private.dispatch(uuid) from public,anon,authenticated;
create function atm_completion_private.enqueue() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.change_type='finished' and new.atm_finish_actor is not null and new.atm_push_claimed_at is null then
  insert into atm_completion_private.queue(event_id) values(new.id) on conflict do nothing;
  perform atm_completion_private.dispatch(new.id);
 end if;
 return new;
end $$;
revoke all on function atm_completion_private.enqueue() from public,anon,authenticated;
create trigger atm_completion_push_enqueue after insert on public.atm_calendar_changes
for each row when (new.change_type='finished') execute function atm_completion_private.enqueue();
create function public.atm_completion_push_claim(p_event uuid,p_token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare q atm_completion_private.queue%rowtype; c public.atm_calendar_changes%rowtype; lease timestamptz;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Sin permiso' using errcode='42501';end if;
 select * into q from atm_completion_private.queue where event_id=p_event and token=p_token and not done and (lease_until is null or lease_until<=clock_timestamp()) for update;
 if not found then return null;end if;
 select * into c from public.atm_calendar_changes where id=p_event and change_type='finished' and exists(select 1 from public.atm_profiles where user_id=recipient_id and active and role='admin');
 if not found then update atm_completion_private.queue set done=true where event_id=p_event;return null;end if;
 lease:=clock_timestamp()+interval '2 minutes';
 update atm_completion_private.queue set lease_until=lease where event_id=p_event;
 return jsonb_build_object('id',c.id,'recipient_id',c.recipient_id,'work_item_id',c.work_item_id,'vehicle',c.vehicle,'detail',c.detail,'sent_subscriptions',q.sent_subscriptions,'lease',lease);
end $$;
revoke all on function public.atm_completion_push_claim(uuid,uuid) from public,anon,authenticated;
grant execute on function public.atm_completion_push_claim(uuid,uuid) to service_role;
create function public.atm_completion_push_ack(p_event uuid,p_token uuid,p_lease timestamptz,p_sent uuid[],p_done boolean) returns boolean
language plpgsql security definer set search_path='' as $$
declare q atm_completion_private.queue%rowtype;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'Sin permiso' using errcode='42501';end if;
 select * into q from atm_completion_private.queue where event_id=p_event and token=p_token and lease_until=p_lease for update;
 if not found then return false;end if;
 update atm_completion_private.queue set sent_subscriptions=array(select distinct x from unnest(q.sent_subscriptions||coalesce(p_sent,'{}'::uuid[])) x),
  lease_until=null,done=p_done where event_id=p_event;
 if cardinality(coalesce(p_sent,'{}'::uuid[]))>0 then
  update public.atm_calendar_changes set atm_push_claimed_at=coalesce(atm_push_claimed_at,clock_timestamp()) where id=p_event;
 end if;
 return true;
end $$;
revoke all on function public.atm_completion_push_ack(uuid,uuid,timestamptz,uuid[],boolean) from public,anon,authenticated;
grant execute on function public.atm_completion_push_ack(uuid,uuid,timestamptz,uuid[],boolean) to service_role;
create function atm_completion_private.retry_pending() returns void
language plpgsql security definer set search_path='' as $$
declare id uuid;
begin
 for id in select event_id from atm_completion_private.queue where not done and attempts<8 and next_attempt<=clock_timestamp() and (lease_until is null or lease_until<=clock_timestamp()) order by next_attempt limit 10
 loop perform atm_completion_private.dispatch(id);end loop;
end $$;
revoke all on function atm_completion_private.retry_pending() from public,anon,authenticated;
select cron.schedule('atm-completion-push-retry','*/5 * * * *','select atm_completion_private.retry_pending()');
