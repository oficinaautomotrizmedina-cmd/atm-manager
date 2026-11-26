-- Restore stable UI first; keep newly assigned deadline data for recovery.
set local lock_timeout = '2s';
drop trigger if exists atm_deadline_guard_notice on public.atm_notices;
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
drop function if exists public.atm_set_task_deadline(uuid,timestamptz,timestamptz);
drop function if exists public.atm_reactivate_task(uuid,timestamptz);
drop function if exists atm_deadline_private.guard_notice();
drop function if exists atm_deadline_private.is_locked(uuid,uuid,date,text);
drop schema if exists atm_deadline_private;
-- Deadline columns remain inert, preserving data. Do not drop them without backup.

drop function if exists public.atm_deadline_clock();
