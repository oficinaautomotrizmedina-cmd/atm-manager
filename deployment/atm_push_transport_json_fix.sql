create or replace function atm_completion_private.dispatch(p_event uuid) returns void
language plpgsql security definer set search_path='' as $$
declare q atm_completion_private.queue%rowtype; result integer;
begin
 select * into q from atm_completion_private.queue where event_id=p_event and not done and attempts<8 and next_attempt<=clock_timestamp() and (lease_until is null or lease_until<=clock_timestamp());
 if not found then return;end if;
 -- Do not lock or update the queue before the worker calls back into this database.
 begin
  perform atm_completion_private.http_set_curlopt('CURLOPT_TIMEOUT_MS','10000');
  perform atm_completion_private.http_set_curlopt('CURLOPT_CONNECTTIMEOUT_MS','4000');
  select status into result from atm_completion_private.http_post('https://mnwqvzhjkkoxcjxdolac.supabase.co/functions/v1/atm-push',
   jsonb_build_object('action','completion-worker','event_id',q.event_id,'token',q.token)::text,'application/json');
 exception when others then result:=null;end;
 update atm_completion_private.queue set attempts=attempts+1,next_attempt=clock_timestamp()+interval '2 minutes',last_http_status=result where event_id=q.event_id;
end $$;
