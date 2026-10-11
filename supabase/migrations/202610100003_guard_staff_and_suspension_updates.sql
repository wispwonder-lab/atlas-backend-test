-- Atlas phase 1b: block self-escalation through row updates and prevent
-- practice administrators from changing their own suspension state.
-- Column-level access and role-scoped policies should be reviewed in a later pass.

CREATE OR REPLACE FUNCTION public.guard_staff_role_self_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL AND OLD.user_id = auth.uid() THEN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id
       OR NEW.practice_id IS DISTINCT FROM OLD.practice_id
       OR NEW.role IS DISTINCT FROM OLD.role
       OR NEW.full_name IS DISTINCT FROM OLD.full_name
       OR NEW.is_active IS DISTINCT FROM OLD.is_active
       OR NEW.location_id IS DISTINCT FROM OLD.location_id
       OR NEW.practitioner_id IS DISTINCT FROM OLD.practitioner_id
       OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
      RAISE EXCEPTION 'Staff may only update their own solo-mode preference'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS guard_staff_role_self_update ON public.staff_roles;
CREATE TRIGGER guard_staff_role_self_update
BEFORE UPDATE ON public.staff_roles
FOR EACH ROW
EXECUTE FUNCTION public.guard_staff_role_self_update();

CREATE OR REPLACE FUNCTION public.guard_practice_account_status_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.account_status IS DISTINCT FROM OLD.account_status
     AND NOT public.is_atlas_admin()
     AND COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Only an Atlas administrator may change practice account status'
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS guard_practice_account_status_update ON public.practices;
CREATE TRIGGER guard_practice_account_status_update
BEFORE UPDATE OF account_status ON public.practices
FOR EACH ROW
EXECUTE FUNCTION public.guard_practice_account_status_update();
