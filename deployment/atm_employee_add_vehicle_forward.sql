-- Narrow server entrypoint: employee can only create their own ordinary task today.
create function public.atm_employee_add_vehicle(p_vehicle text,p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
 actor uuid:=auth.uid();
 today date:=(clock_timestamp() at time zone 'America/El_Salvador')::date;
 vehicle_name text:=btrim(regexp_replace(coalesce(p_vehicle,''),'[[:space:]]+',' ','g'));
 normalized text:=lower(vehicle_name);
 item public.atm_work_items%rowtype;
 next_order integer;
begin
 if actor is null or not exists(select 1 from public.atm_profiles where user_id=actor and active and role in ('employee','supervisor')) then
  raise exception 'Sin permiso' using errcode='42501';
 end if;
 if p_request_id is null or char_length(vehicle_name) not between 1 and 130 then
  raise exception 'Escribí marca, modelo y año válidos.' using errcode='22023';
 end if;
 -- Serialize with the existing transfer function; identical concurrent submissions cannot create duplicates.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('atm:transfer:day:'||today::text)::bigint);
 select * into item from public.atm_work_items where id=p_request_id;
 if found then
  if item.created_by=actor and item.assigned_to=actor and item.kind='job' and item.work_day=today and lower(btrim(regexp_replace(item.vehicle,'[[:space:]]+',' ','g')))=normalized then
   return jsonb_build_object('ok',true,'created',false,'work',to_jsonb(item));
  end if;
  raise exception 'La solicitud ya fue utilizada. Revisá el calendario.' using errcode='40001';
 end if;
 if exists(select 1 from public.atm_work_items w where w.assigned_to=actor and w.work_day=today
  and lower(btrim(regexp_replace(w.vehicle,'[[:space:]]+',' ','g')))=normalized)
 or exists(select 1 from public.atm_notices n where n.target_employee_id=actor and n.work_day=today and n.work_item_id is null
  and n.copied_from_notice_id is null and n.category in ('Registrar bitácora','Informar avance')
  and n.body not like '[ATM_TAREA_ACTIVA_V1]%' and lower(btrim(regexp_replace(n.vehicle_caption,'[[:space:]]+',' ','g')))=normalized)
 then raise exception 'Este vehículo ya aparece en tus actividades de hoy.' using errcode='23505';end if;
 select coalesce(max(sort_order),0)+1 into next_order from public.atm_work_items where assigned_to=actor and work_day=today;
 insert into public.atm_work_items(id,kind,vehicle,instructions,work_day,assigned_to,sort_order,created_by)
 values(p_request_id,'job',vehicle_name,'',today,actor,next_order,actor) returning * into item;
 -- Existing calendar tracking creates an assignment notice to the employee.
 -- It is their own action, not a new instruction from administration.
 update public.atm_calendar_changes set read_at=clock_timestamp()
 where work_item_id=item.id and recipient_id=actor and change_type='assigned' and read_at is null;
 return jsonb_build_object('ok',true,'created',true,'work',to_jsonb(item));
end;
$$;
revoke all on function public.atm_employee_add_vehicle(text,uuid) from public,anon,authenticated;
grant execute on function public.atm_employee_add_vehicle(text,uuid) to authenticated;
