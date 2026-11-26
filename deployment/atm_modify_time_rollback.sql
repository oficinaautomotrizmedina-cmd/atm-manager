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
 if w.atm_paused_at is not null then raise exception 'Reanudá el tiempo antes de ampliarlo.' using errcode='40001'; end if;
 if p_due_at is null or not isfinite(p_due_at) or p_due_at<=t or
    (w.atm_due_at is not null and p_due_at<=w.atm_due_at) then
   raise exception 'Seleccioná una fecha posterior al plazo actual y a la hora presente';
 end if;
 update public.atm_work_items set atm_due_at=p_due_at,atm_window_started_at=t,atm_tokens_remaining=2 where id=w.id;
 return jsonb_build_object('id',w.id,'due_at',p_due_at,'started_at',t,'tokens',2,'paused_at',null,'server_now',t);
end; $function$
;
