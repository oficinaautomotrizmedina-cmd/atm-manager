-- Optional deadlines; existing rows remain unchanged.
set local lock_timeout = '2s';
alter table public.atm_work_items
 add column atm_due_at timestamptz,
 add column atm_window_started_at timestamptz,
 add column atm_tokens_remaining smallint,
 add constraint atm_deadline_consistent check (
   (atm_due_at is null and atm_window_started_at is null and atm_tokens_remaining is null)
   or (atm_due_at is not null and atm_window_started_at is not null
       and atm_due_at > atm_window_started_at and atm_tokens_remaining is not null
       and atm_tokens_remaining between 0 and 2)
 );
create schema atm_deadline_private;
revoke all on schema atm_deadline_private from public, anon, authenticated;
create function public.atm_set_task_deadline(p_work_id uuid,p_due_at timestamptz,p_expected_due_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
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
 if p_due_at is null or not isfinite(p_due_at) or p_due_at<=t or
    (w.atm_due_at is not null and p_due_at<=w.atm_due_at) then
   raise exception 'Seleccioná una fecha posterior al plazo actual y a la hora presente';
 end if;
 update public.atm_work_items set atm_due_at=p_due_at,atm_window_started_at=t,atm_tokens_remaining=2 where id=w.id;
 return jsonb_build_object('id',w.id,'due_at',p_due_at,'started_at',t,'tokens',2,'server_now',t);
end; $$;
revoke all on function public.atm_set_task_deadline(uuid,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.atm_set_task_deadline(uuid,timestamptz,timestamptz) to authenticated;
create function public.atm_reactivate_task(p_work_id uuid,p_expected_due_at timestamptz)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w public.atm_work_items%rowtype; t timestamptz; actor uuid:=auth.uid();
begin
 if actor is null or not exists(select 1 from public.atm_profiles where user_id=actor and active and role in ('employee','supervisor')) then
   raise exception 'Sin permiso' using errcode='42501';
 end if;
 select * into w from public.atm_work_items where id=p_work_id and assigned_to=actor for update;
 if not found then raise exception 'Tarea no disponible' using errcode='42501';end if;
 t:=clock_timestamp();
 if w.atm_due_at is null or w.atm_due_at is distinct from p_expected_due_at or w.atm_due_at>t or coalesce(w.atm_tokens_remaining,0)<1 then
   raise exception 'No se puede reactivar esta tarea. Actualizá el calendario.' using errcode='40001';
 end if;
 update public.atm_work_items set atm_due_at=t+interval '4 hours',atm_window_started_at=t,atm_tokens_remaining=w.atm_tokens_remaining-1 where id=w.id;
 return jsonb_build_object('id',w.id,'due_at',t+interval '4 hours','started_at',t,'tokens',w.atm_tokens_remaining-1,'server_now',t);
end; $$;
revoke all on function public.atm_reactivate_task(uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.atm_reactivate_task(uuid,timestamptz) to authenticated;
create function atm_deadline_private.is_locked(p_actor uuid,p_work uuid,p_day date,p_vehicle text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare item record;
begin
 if p_actor is null then return false; end if;
 for item in select w.atm_due_at from public.atm_work_items w
   where w.assigned_to=p_actor and
   (w.id=p_work or (p_work is null and p_day is not null and p_vehicle is not null
      and w.work_day=p_day and lower(btrim(w.vehicle))=lower(btrim(p_vehicle))))
   order by w.id for share
 loop
   if item.atm_due_at is not null and item.atm_due_at<=clock_timestamp() then return true; end if;
 end loop;
 return false;
end; $$;
revoke all on function atm_deadline_private.is_locked(uuid,uuid,date,text) from public,anon,authenticated;
create function atm_deadline_private.guard_notice()
returns trigger language plpgsql security definer set search_path = '' as $$
declare actor uuid:=auth.uid();
begin
 if actor is null or public.atm_is_admin() then return new; end if;
 if tg_op='UPDATE' then
   if atm_deadline_private.is_locked(actor,old.work_item_id,old.work_day,old.vehicle_caption) then
     raise exception 'Tarea vencida. Reactivá la tarea' using errcode='42501';
   end if;
 end if;
 if atm_deadline_private.is_locked(actor,new.work_item_id,new.work_day,new.vehicle_caption) then
   raise exception 'Tarea vencida. Reactivá la tarea' using errcode='42501';
 end if;
 return new;
end; $$;
revoke all on function atm_deadline_private.guard_notice() from public,anon,authenticated;
create trigger atm_deadline_guard_notice before insert or update on public.atm_notices
 for each row execute function atm_deadline_private.guard_notice();
CREATE OR REPLACE FUNCTION public.atm_log_delete_confirm(p_actor uuid, p_mode text, p_day date, p_ids uuid[], p_expected_ids uuid[], p_confirm text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_preview jsonb;
 v_actual uuid[];
 v_count int;
 v_deleted int;
begin
 if p_confirm is distinct from 'ELIMINAR' then raise exception 'Confirmación requerida';end if;
 if p_expected_ids is null or cardinality(p_expected_ids)<1 or cardinality(p_expected_ids)>5000 then
  raise exception 'No hay registros confirmados para eliminar';
 end if;
 lock table public.atm_notices in share row exclusive mode;
 v_preview:=public.atm_log_delete_preview(p_actor,p_mode,p_day,p_ids);
 select coalesce(array_agg(v order by v),'{}'::uuid[]) into v_actual
 from jsonb_array_elements_text(v_preview->'ids') q(value)
 cross join lateral (select q.value::uuid as v) x;
 select count(*) into v_count from unnest(p_expected_ids) id;
 if cardinality(v_actual) <> v_count or
    v_actual <> (select array_agg(x order by x) from unnest(p_expected_ids) x)
 then
   raise exception 'Los registros cambiaron desde la vista previa. Revisá nuevamente antes de borrar';
 end if;
 if not exists(select 1 from public.atm_profiles where user_id=p_actor and active and role='admin') then
   if exists(select 1 from public.atm_notices n where n.id=any(v_actual)
     and atm_deadline_private.is_locked(p_actor,n.work_item_id,n.work_day,n.vehicle_caption)) then
     raise exception 'Tarea vencida. Reactivá la tarea antes de modificar sus registros' using errcode='42501';
   end if;
 end if;
 insert into public.atm_deleted_log_messages(notice_id,deleted_by)
 select x,p_actor from unnest(v_actual) x
 on conflict (notice_id) do nothing;
 delete from public.atm_notices n where n.id=any(v_actual);
 get diagnostics v_deleted=row_count;
 if v_deleted<>v_count then
   raise exception 'No se pudieron eliminar todos los registros. Se cancelan los cambios';
 end if;
 if exists(select 1 from public.atm_notices n where n.id=any(v_actual)) then
   raise exception 'Los registros todavía existen. Se cancela el borrado';
 end if;
 return jsonb_build_object('ok',true,'deleted',true,'count',v_deleted,'ids',to_jsonb(v_actual));
end;$function$;
