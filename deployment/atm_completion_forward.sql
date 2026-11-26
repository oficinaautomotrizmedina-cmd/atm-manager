-- Add completion state without modifying any existing task, notice or payroll.
set local lock_timeout = '2s';
alter table public.atm_work_items
 add column atm_finished_at timestamptz,
 add column atm_finish_correction boolean,
 add column atm_finished_by uuid,
 add constraint atm_completion_consistent check (
  (atm_finished_at is null and atm_finish_correction is null and atm_finished_by is null)
  or (atm_finished_at is not null and atm_finish_correction is not null and atm_finished_by is not null)
 );
alter table public.atm_work_items drop constraint atm_deadline_consistent;
alter table public.atm_work_items add constraint atm_deadline_consistent check (
  (atm_due_at is null and atm_window_started_at is null and
    (atm_tokens_remaining is null or (atm_finished_at is not null and atm_tokens_remaining between 0 and 2)))
  or (atm_due_at is not null and atm_window_started_at is not null and
    atm_due_at>atm_window_started_at and atm_tokens_remaining is not null and atm_tokens_remaining between 0 and 2)
);
CREATE OR REPLACE FUNCTION atm_deadline_private.is_locked(p_actor uuid, p_work uuid, p_day date, p_vehicle text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare item record;
begin
 if p_actor is null then return false; end if;
 for item in select w.atm_due_at,w.atm_finished_at from public.atm_work_items w
   where w.assigned_to=p_actor and
   (w.id=p_work or (p_work is null and p_day is not null and p_vehicle is not null
      and w.work_day=p_day and lower(btrim(regexp_replace(w.vehicle,'[[:space:]]+',' ','g')))=lower(btrim(regexp_replace(p_vehicle,'[[:space:]]+',' ','g')))))
   order by w.id for share
 loop
   if item.atm_finished_at is not null or (item.atm_due_at is not null and item.atm_due_at<=clock_timestamp()) then return true; end if;
 end loop;
 return false;
end; $function$;
CREATE OR REPLACE FUNCTION atm_deadline_private.guard_notice()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid:=auth.uid(); marker jsonb; focus_uuid uuid; prefix text:='[ATM_TAREA_ACTIVA_V1]';
begin
 if actor is null or public.atm_is_admin() then return new; end if;
 -- Internal focus notices normally have no work_item_id. Validate their real target.
 if new.category='Registrar bitácora' and left(new.body,length(prefix))=prefix then
   begin
     marker:=substring(new.body from length(prefix)+1)::jsonb;
     if marker->>'kind' in ('job','booking') then focus_uuid:=(marker->>'uuid')::uuid; end if;
   exception when invalid_text_representation then focus_uuid:=null;
   end;
   if focus_uuid is not null and atm_deadline_private.is_locked(actor,focus_uuid,null,null) then
     raise exception 'Tarea bloqueada. Reactivá la tarea' using errcode='42501';
   end if;
 end if;
 if tg_op='UPDATE' then
   if atm_deadline_private.is_locked(actor,old.work_item_id,old.work_day,old.vehicle_caption) then
     raise exception 'Tarea bloqueada. Reactivá la tarea' using errcode='42501';
   end if;
 end if;
 if atm_deadline_private.is_locked(actor,new.work_item_id,new.work_day,new.vehicle_caption) then
   raise exception 'Tarea bloqueada. Reactivá la tarea' using errcode='42501';
 end if;
 return new;
end; $function$;
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
     raise exception 'Tarea bloqueada. Reactivá la tarea antes de modificar sus registros' using errcode='42501';
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
CREATE OR REPLACE FUNCTION public.atm_reactivate_task(p_work_id uuid, p_expected_due_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare w public.atm_work_items%rowtype; t timestamptz; actor uuid:=auth.uid();
begin
 if actor is null or not exists(select 1 from public.atm_profiles where user_id=actor and active and role in ('employee','supervisor')) then
   raise exception 'Sin permiso' using errcode='42501';
 end if;
 select * into w from public.atm_work_items where id=p_work_id and assigned_to=actor for update;
 if not found then raise exception 'Tarea no disponible' using errcode='42501';end if;
 t:=clock_timestamp();
 if w.atm_finished_at is not null or w.atm_due_at is null or w.atm_due_at is distinct from p_expected_due_at or w.atm_due_at>t or coalesce(w.atm_tokens_remaining,0)<1 then
   raise exception 'No se puede reactivar esta tarea. Actualizá el calendario.' using errcode='40001';
 end if;
 update public.atm_work_items set atm_due_at=t+interval '4 hours',atm_window_started_at=t,atm_tokens_remaining=w.atm_tokens_remaining-1 where id=w.id;
 return jsonb_build_object('id',w.id,'due_at',t+interval '4 hours','started_at',t,'tokens',w.atm_tokens_remaining-1,'server_now',t);
end; $function$;
-- Single atomic transition. Existing deadline RPC for admin extension stays unchanged.
create function public.atm_task_transition(p_work_id uuid,p_expected_due_at timestamptz,p_expected_finished_at timestamptz,p_action text,p_correction boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.atm_work_items%rowtype; actor uuid:=auth.uid(); t timestamptz; admin boolean;
begin
 if actor is null or p_action is null or p_action not in ('finish','reactivate','cancel_deadline') then
  raise exception 'Sin permiso' using errcode='42501';
 end if;
 admin:=public.atm_is_admin();
 if p_action='cancel_deadline' then
  if not admin then raise exception 'Sin permiso' using errcode='42501'; end if;
 elsif not exists(select 1 from public.atm_profiles where user_id=actor and active and role in ('employee','supervisor')) then
  raise exception 'Sin permiso' using errcode='42501';
 end if;
 select * into w from public.atm_work_items where id=p_work_id and (p_action='cancel_deadline' or assigned_to=actor) for update;
 if not found then raise exception 'Tarea no disponible' using errcode='42501'; end if;
 if w.atm_due_at is distinct from p_expected_due_at or w.atm_finished_at is distinct from p_expected_finished_at then
  raise exception 'La tarea cambió. Actualizá el calendario.' using errcode='40001';
 end if;
 t:=clock_timestamp();
 if p_action='finish' then
  if p_correction is null or w.atm_finished_at is not null or (w.atm_due_at is not null and w.atm_due_at<=t)
   or w.work_day<>(t at time zone 'America/El_Salvador')::date then
   raise exception 'La tarea no está disponible para finalizar.' using errcode='40001';
  end if;
  update public.atm_work_items set atm_finished_at=t,atm_finished_by=actor,
   atm_finish_correction=p_correction,atm_tokens_remaining=coalesce(w.atm_tokens_remaining,2)
   where id=w.id returning * into w;
 elsif p_action='reactivate' then
  if p_correction is not null or (w.atm_finished_at is null and (w.atm_due_at is null or w.atm_due_at>t))
   or coalesce(w.atm_tokens_remaining,0)<1 then
   raise exception 'No se puede reactivar esta tarea. Actualizá el calendario.' using errcode='40001';
  end if;
  update public.atm_work_items set atm_due_at=t+interval '4 hours',atm_window_started_at=t,
   atm_tokens_remaining=w.atm_tokens_remaining-1,atm_finished_at=null,atm_finish_correction=null,atm_finished_by=null
   where id=w.id returning * into w;
 else
  if p_correction is not null or w.atm_due_at is null then
   raise exception 'No hay plazo para cancelar.' using errcode='40001';
  end if;
  update public.atm_work_items set atm_due_at=null,atm_window_started_at=null,
   atm_tokens_remaining=case when w.atm_finished_at is not null then w.atm_tokens_remaining else null end
   where id=w.id returning * into w;
 end if;
 return jsonb_build_object('id',w.id,'due_at',w.atm_due_at,'started_at',w.atm_window_started_at,
  'tokens',w.atm_tokens_remaining,'finished_at',w.atm_finished_at,'correction',w.atm_finish_correction,'server_now',t);
end; $$;
revoke all on function public.atm_task_transition(uuid,timestamptz,timestamptz,text,boolean) from public,anon,authenticated;
grant execute on function public.atm_task_transition(uuid,timestamptz,timestamptz,text,boolean) to authenticated;
