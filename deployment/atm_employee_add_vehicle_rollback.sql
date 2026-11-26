-- Remove entrypoint only; employee-created work and all related logs remain intact.
DROP FUNCTION IF EXISTS public.atm_employee_add_vehicle(text,uuid);
