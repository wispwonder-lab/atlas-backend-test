-- Atlas secure public booking operations.
-- These RPCs are additive. Public table policies remain unchanged until the
-- frontend branch is reviewed and the cutover is coordinated.

CREATE OR REPLACE FUNCTION public.get_public_booked_slots(
  p_practitioner_id uuid,
  p_start_date date,
  p_end_date date
)
RETURNS TABLE (
  appointment_date date,
  appointment_time time,
  duration_minutes integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF p_practitioner_id IS NULL
     OR p_start_date IS NULL
     OR p_end_date IS NULL
     OR p_end_date < p_start_date
     OR p_end_date > p_start_date + 45 THEN
    RAISE EXCEPTION 'Invalid availability request';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.practitioners AS pr
    JOIN public.practices AS pc ON pc.id = pr.practice_id
    WHERE pr.id = p_practitioner_id
      AND pr.is_active = true
      AND pr.is_available = true
      AND pc.account_status = 'active'
  ) THEN
    RAISE EXCEPTION 'Practitioner is not available for public booking';
  END IF;

  RETURN QUERY
  SELECT a.appointment_date,
         a.appointment_time,
         COALESCE(a.duration_minutes, pr.appointment_duration_minutes, 30)
  FROM public.appointments AS a
  JOIN public.practitioners AS pr ON pr.id = a.practitioner_id
  WHERE a.practitioner_id = p_practitioner_id
    AND a.appointment_date BETWEEN p_start_date AND p_end_date
    AND lower(COALESCE(a.status, 'booked')) NOT IN
        ('cancelled', 'canceled', 'no-show', 'noshow', 'completed');
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_public_booking(
  p_practice_id uuid,
  p_location_id uuid,
  p_practitioner_id uuid,
  p_first_name text,
  p_surname text,
  p_email text,
  p_mobile_number text,
  p_date_of_birth date,
  p_appointment_date date,
  p_appointment_time time,
  p_reason text DEFAULT NULL
)
RETURNS TABLE (
  appointment_id uuid,
  patient_first_name text,
  patient_surname text,
  patient_email text,
  practitioner_name text,
  practitioner_role text,
  location_name text,
  appointment_date date,
  appointment_time time
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_duration integer;
  v_patient_id uuid;
  v_appointment_id uuid;
  v_practitioner_name text;
  v_practitioner_role text;
  v_location_name text;
  v_practice_status text;
  v_start timestamp without time zone;
BEGIN
  IF p_practice_id IS NULL OR p_location_id IS NULL OR p_practitioner_id IS NULL
     OR NULLIF(btrim(p_first_name), '') IS NULL
     OR NULLIF(btrim(p_surname), '') IS NULL
     OR NULLIF(btrim(p_email), '') IS NULL
     OR NULLIF(btrim(p_mobile_number), '') IS NULL
     OR p_appointment_date IS NULL OR p_appointment_time IS NULL
     OR length(btrim(p_first_name)) > 100
     OR length(btrim(p_surname)) > 100
     OR length(btrim(p_email)) > 254
     OR length(btrim(p_mobile_number)) > 40
     OR length(COALESCE(p_reason, '')) > 2000
     OR (p_date_of_birth IS NOT NULL AND p_date_of_birth > CURRENT_DATE) THEN
    RAISE EXCEPTION 'Please check the booking details and try again'
      USING ERRCODE = '22023';
  END IF;

  IF p_appointment_date < CURRENT_DATE
     OR p_appointment_date > CURRENT_DATE + 45 THEN
    RAISE EXCEPTION 'The selected date is outside the booking window'
      USING ERRCODE = '22023';
  END IF;

  SELECT pr.appointment_duration_minutes, pr.name, pr.role, lo.name, pc.account_status
    INTO v_duration, v_practitioner_name, v_practitioner_role, v_location_name, v_practice_status
  FROM public.practitioners AS pr
  JOIN public.practices AS pc ON pc.id = pr.practice_id
  JOIN public.locations AS lo ON lo.id = p_location_id
  WHERE pr.id = p_practitioner_id
    AND pr.practice_id = p_practice_id
    AND pr.location_id = p_location_id
    AND lo.practice_id = p_practice_id
    AND lo.is_active = true
    AND pr.is_active = true
    AND pr.is_available = true
    AND pc.account_status = 'active'
  FOR SHARE OF pr, pc, lo;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'This practice or practitioner is not available for booking'
      USING ERRCODE = '22023';
  END IF;

  v_duration := COALESCE(v_duration, 30);
  IF v_duration < 1 OR v_duration > 480 THEN
    RAISE EXCEPTION 'The practitioner appointment duration is invalid'
      USING ERRCODE = '22023';
  END IF;

  -- Serialize attempts for the same practitioner/date to close the concurrent
  -- booking race, then recheck interval overlap inside this transaction.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_practitioner_id::text),
    pg_catalog.hashtext(p_appointment_date::text)
  );

  v_start := p_appointment_date + p_appointment_time;

  IF EXISTS (
    SELECT 1
    FROM public.appointments AS a
    WHERE a.practitioner_id = p_practitioner_id
      AND a.appointment_date = p_appointment_date
      AND lower(COALESCE(a.status, 'booked')) NOT IN
          ('cancelled', 'canceled', 'no-show', 'noshow', 'completed')
      AND v_start < (a.appointment_date + a.appointment_time)
                    + make_interval(mins => COALESCE(a.duration_minutes, v_duration))
      AND (v_start + make_interval(mins => v_duration))
                    > (a.appointment_date + a.appointment_time)
  ) THEN
    RAISE EXCEPTION 'That time was just taken. Please choose another time.'
      USING ERRCODE = '23P01';
  END IF;

  INSERT INTO public.patients (
    practice_id, first_name, surname, email, mobile_number, date_of_birth
  )
  VALUES (
    p_practice_id, btrim(p_first_name), btrim(p_surname), btrim(p_email),
    btrim(p_mobile_number), p_date_of_birth
  )
  RETURNING id INTO v_patient_id;

  INSERT INTO public.appointments (
    practice_id, location_id, practitioner_id, patient_id,
    appointment_date, appointment_time, duration_minutes, reason, status,
    is_emergency
  )
  VALUES (
    p_practice_id, p_location_id, p_practitioner_id, v_patient_id,
    p_appointment_date, p_appointment_time, v_duration, NULLIF(btrim(p_reason), ''),
    'booked', false
  )
  RETURNING id INTO v_appointment_id;

  INSERT INTO public.appointment_timeline (appointment_id, event_text)
  VALUES (v_appointment_id, 'Appointment created');

  RETURN QUERY
  SELECT v_appointment_id, btrim(p_first_name), btrim(p_surname), btrim(p_email),
         v_practitioner_name, v_practitioner_role, v_location_name,
         p_appointment_date, p_appointment_time;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_booked_slots(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_booked_slots(uuid, date, date) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.create_public_booking(uuid, uuid, uuid, text, text, text, text, date, date, time without time zone, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_public_booking(uuid, uuid, uuid, text, text, text, text, date, date, time without time zone, text) TO anon, authenticated;
