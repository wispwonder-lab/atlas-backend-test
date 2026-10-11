-- Atlas phase 1: snapshot appointment duration and prevent Atlas-admin role escalation.
-- Intentionally does NOT remove public appointment read/insert permissions yet; the
-- replacement booking RPC and frontend must be deployed and verified first.

BEGIN;

ALTER TABLE public.appointments
  ADD COLUMN IF NOT EXISTS duration_minutes integer;

-- Existing future active bookings have no recorded historical duration. Use the
-- practitioner's current setting as an explicit best-available estimate.
UPDATE public.appointments AS a
SET duration_minutes = COALESCE(p.appointment_duration_minutes, 30)
FROM public.practitioners AS p
WHERE a.practitioner_id = p.id
  AND a.practice_id = p.practice_id
  AND a.duration_minutes IS NULL
  AND a.appointment_date >= CURRENT_DATE
  AND lower(COALESCE(a.status, 'booked')) NOT IN
      ('cancelled', 'canceled', 'no-show', 'noshow', 'completed');

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'appointments_duration_minutes_check'
      AND conrelid = 'public.appointments'::regclass
  ) THEN
    ALTER TABLE public.appointments
      ADD CONSTRAINT appointments_duration_minutes_check
      CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 1 AND 1440);
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'staff_roles_role_check'
      AND conrelid = 'public.staff_roles'::regclass
  ) THEN
    ALTER TABLE public.staff_roles
      ADD CONSTRAINT staff_roles_role_check
      CHECK (
        role IS NOT NULL
        AND role IN (
          'atlas_administrator',
          'practice_administrator',
          'practitioner',
          'receptionist'
        )
      );
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.set_appointment_duration_snapshot()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  configured_duration integer;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- Duration is a snapshot; ordinary edits cannot rewrite it.
    NEW.duration_minutes := OLD.duration_minutes;
    RETURN NEW;
  END IF;

  SELECT p.appointment_duration_minutes
    INTO configured_duration
  FROM public.practitioners AS p
  WHERE p.id = NEW.practitioner_id
    AND p.practice_id = NEW.practice_id;

  -- Never trust a client-supplied duration.
  NEW.duration_minutes := COALESCE(configured_duration, 30);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS appointments_duration_snapshot
  ON public.appointments;

CREATE TRIGGER appointments_duration_snapshot
BEFORE INSERT OR UPDATE OF duration_minutes
ON public.appointments
FOR EACH ROW
EXECUTE FUNCTION public.set_appointment_duration_snapshot();

CREATE OR REPLACE FUNCTION public.is_atlas_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff_roles AS sr
    WHERE sr.user_id = auth.uid()
      AND sr.role = 'atlas_administrator'
      AND sr.is_active = true
      AND sr.practice_id IS NULL
  );
$function$;

DROP POLICY IF EXISTS "Practice admins can grant roles to staff at their practice"
  ON public.staff_roles;

CREATE POLICY "Practice admins can grant roles to staff at their practice"
ON public.staff_roles
FOR INSERT
TO authenticated
WITH CHECK (
  role IN ('practice_administrator', 'receptionist', 'practitioner')
  AND practice_id IS NOT NULL
  AND public.is_practice_admin_of(practice_id)
);

COMMIT;