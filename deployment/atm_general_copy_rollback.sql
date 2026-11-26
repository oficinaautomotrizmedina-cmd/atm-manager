-- Restore previous functions; keep additive classification column and data.
CREATE OR REPLACE FUNCTION public.atm_task_transition(p_work_id uuid, p_expected_due_at timestamp with time zone, p_expected_finished_at timestamp with time zone, p_action text, p_correction boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end; $function$
;

CREATE OR REPLACE FUNCTION public.atm_transfer_day(p_source date, p_destination date, p_mode text, p_scope_type text, p_scope_employee uuid, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_actor uuid := (SELECT auth.uid());
 v_saved public.atm_day_transfers%ROWTYPE;
 v_work RECORD;
 v_log RECORD;
 v_new uuid;
 v_order integer;
 v_work_count integer := 0;
 v_log_count integer := 0;
 v_work_map jsonb := '{}'::jsonb;
 v_result jsonb;
BEGIN
 IF v_actor IS NULL OR NOT EXISTS (
   SELECT 1 FROM public.atm_profiles
   WHERE user_id=v_actor AND active=true AND role='admin'
 ) THEN RAISE EXCEPTION 'Operación reservada a un administrador activo' USING ERRCODE='42501'; END IF;
 IF p_request_id IS NULL OR p_source IS NULL OR p_destination IS NULL OR p_source=p_destination
    OR p_mode NOT IN ('copy','move') OR p_mode IS NULL
    OR p_scope_type NOT IN ('all','employee','pending') OR p_scope_type IS NULL
    OR (p_scope_type='employee' AND (p_scope_employee IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.atm_profiles
       WHERE user_id=p_scope_employee AND active=true AND role IN ('employee','supervisor')
    )))
    OR (p_scope_type<>'employee' AND p_scope_employee IS NOT NULL)
 THEN RAISE EXCEPTION 'Parámetros de traslado inválidos' USING ERRCODE='22023'; END IF;

 -- Serialized by operation UUID: a network retry returns the original result.
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('atm:transfer:id:'||p_request_id::text)::bigint);
 SELECT * INTO v_saved FROM public.atm_day_transfers WHERE request_id=p_request_id;
 IF FOUND THEN
   IF v_saved.actor_id<>v_actor OR v_saved.source_day<>p_source
      OR v_saved.destination_day<>p_destination OR v_saved.mode<>p_mode
      OR v_saved.scope_type<>p_scope_type
      OR v_saved.scope_employee IS DISTINCT FROM p_scope_employee
   THEN RAISE EXCEPTION 'Este identificador ya pertenece a otra operación' USING ERRCODE='22023'; END IF;
   RETURN v_saved.result;
 END IF;

 -- Avoid assigning conflicting destination positions when users copy concurrently.
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('atm:transfer:day:'||p_destination::text)::bigint);

 FOR v_work IN
  SELECT w.* FROM public.atm_work_items w
  WHERE w.work_day=p_source AND (
   p_scope_type='all'
   OR (p_scope_type='pending' AND w.assigned_to IS NULL)
   OR (p_scope_type='employee' AND w.assigned_to=p_scope_employee))
  ORDER BY w.assigned_to NULLS LAST,w.sort_order NULLS LAST,w.created_at,w.id
  FOR UPDATE
 LOOP
   IF v_work.assigned_to IS NULL THEN v_order:=NULL;
   ELSE
     SELECT COALESCE(MAX(w.sort_order),0)+1 INTO v_order
     FROM public.atm_work_items w
     WHERE w.work_day=p_destination AND w.assigned_to=v_work.assigned_to;
   END IF;

   IF p_mode='copy' THEN
     v_new:=pg_catalog.gen_random_uuid();
     INSERT INTO public.atm_work_items(
       id,kind,vehicle,instructions,service_type,service_other,priority,
       reception_start,reception_end,work_day,assigned_to,sort_order,
       status,created_by
     ) VALUES (
       v_new,v_work.kind,v_work.vehicle,v_work.instructions,
       v_work.service_type,v_work.service_other,v_work.priority,
       v_work.reception_start,v_work.reception_end,p_destination,
       v_work.assigned_to,v_order,'pending',v_actor
     );
   ELSE
     v_new:=v_work.id;
     UPDATE public.atm_work_items
       SET work_day=p_destination,sort_order=v_order
       WHERE id=v_work.id;
   END IF;
   v_work_map:=v_work_map || pg_catalog.jsonb_build_object(v_work.id::text,v_new::text);
   v_work_count:=v_work_count+1;
 END LOOP;

 IF p_mode='copy' THEN
   FOR v_log IN
     SELECT n.* FROM public.atm_notices n
     WHERE n.category='Registrar bitácora' AND n.work_day=p_source
       AND (
        (n.work_item_id IS NOT NULL AND v_work_map ? n.work_item_id::text)
        OR (n.work_item_id IS NULL AND
          ((p_scope_type='employee' AND n.target_employee_id=p_scope_employee)
           OR (p_scope_type='all' AND EXISTS (
              SELECT 1 FROM public.atm_profiles tp
              WHERE tp.user_id=n.target_employee_id AND tp.role IN ('employee','supervisor')
           ))))
       )
     ORDER BY n.created_at,n.id
   LOOP
     INSERT INTO public.atm_notices(
       id,author_id,target_employee_id,work_item_id,category,body,
       allow_reply,reply_to,vehicle_caption,work_day,priority_caption,
       task_snapshot,copied_from_notice_id,copied_from_work_day,copied_by
     ) VALUES (
       pg_catalog.gen_random_uuid(),v_log.author_id,v_log.target_employee_id,
       CASE WHEN v_log.work_item_id IS NULL THEN NULL
            ELSE (v_work_map->>v_log.work_item_id::text)::uuid END,
       'Registrar bitácora',v_log.body,false,NULL,
       v_log.vehicle_caption,p_destination,v_log.priority_caption,
       v_log.task_snapshot,v_log.id,p_source,v_actor
     );
     v_log_count:=v_log_count+1;
   END LOOP;
 ELSE
   UPDATE public.atm_notices n SET work_day=p_destination
   WHERE n.category='Registrar bitácora' AND n.work_day=p_source
     AND (
        (n.work_item_id IS NOT NULL AND v_work_map ? n.work_item_id::text)
        OR (n.work_item_id IS NULL AND
          ((p_scope_type='employee' AND n.target_employee_id=p_scope_employee)
           OR (p_scope_type='all' AND EXISTS (
              SELECT 1 FROM public.atm_profiles tp
              WHERE tp.user_id=n.target_employee_id AND tp.role IN ('employee','supervisor')
           ))))
     );
   GET DIAGNOSTICS v_log_count=ROW_COUNT;
 END IF;

 v_result:=pg_catalog.jsonb_build_object(
  'ok',true,'mode',p_mode,'source_day',p_source,'destination_day',p_destination,
  'work_count',v_work_count,'log_count',v_log_count,'request_id',p_request_id
 );
 INSERT INTO public.atm_day_transfers(
  request_id,actor_id,source_day,destination_day,mode,scope_type,scope_employee,result
 ) VALUES(p_request_id,v_actor,p_source,p_destination,p_mode,p_scope_type,p_scope_employee,v_result);
 RETURN v_result;
END;
$function$
;
