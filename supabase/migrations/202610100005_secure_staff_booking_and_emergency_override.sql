-- Atlas secure staff booking RPC.
-- Authenticated staff can create a booking in their own practice/location.
-- Emergency overlap requires a scoped receptionist or practice administrator,
-- an explicit confirmation flag, and a non-empty audit reason.

CREATE OR REPLACE FUNCTION public.create_staff_booking(
  p_practice_id uuid,
  p_location_id uuid,
  p_practitioner_id uuid,
  p_appointment_date date,
  p_appointment_time time,
  p_patient_id uuid DEFAULT NULL,
  p_first_name text DEFAULT NULL,
  p_surname text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_mobile_number text DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_is_emergency boolean DEFAULT false,
  p_allow_overlap boolean DEFAULT false,
  p_override_reason text DEFAULT NULL
)
RETURNS TABLE (
  appointment_id uuid,
  patient_id uuid,
  patient_first_name text,
  patient_surname text,
  practitioner_name text,
  location_name text,
  appointment_date date,
  appointment_time time,
  is_emergency boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_duration integer;
  v_patient_id uuid;
  v_appointment_id uuid;
  v_first text;
  v_surname text;
  v_practitioner_name text;
  v_location_name text;
  v_role text;
  v_is_atlas_admin boolean;
  v_start timestamp without time zone;
  v_has_overlap boolean;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Sign in is required to book for a practice'
      USING ERRCODE = '42501';
  END IF;

  -- Normalize nullable boolean inputs before any authorization or conflict checks.
  p_is_emergency := COALESCE(p_is_emergency, false);
  p_allow_overlap := COALESCE(p_allow_overlap, false);

  IF p_practice_id IS NULL OR p_location_id IS NULL OR p_practitioner_id IS NULL
     OR p_appointment_date IS NULL OR p_appointment_time IS NULL
     OR length(COALESCE(p_reason, '')) > 2000
     OR length(COALESCE(p_override_reason, '')) > 1000 THEN
    RAISE EXCEPTION 'Please check the booking details'
      USING ERRCODE = '22023';
  END IF;

  IF p_appointment_date < (now() AT TIME ZONE 'Africa/Johannesburg')::date
     OR p_appointment_date > (now() AT TIME ZONE 'Africa/Johannesburg')::date + 90 THEN
    RAISE EXCEPTION 'The selected date is outside the permitted booking window'
      USING ERRCODE = '22023';
  END IF;

  IF p_is_emergency AND NULLIF(btrim(p_reason), '') IS NULL THEN
    RAISE EXCEPTION 'An emergency booking requires a reason'
      USING ERRCODE = '22023';
  END IF;

  SELECT sr.role
    INTO v_role
  FROM public.staff_roles AS sr
  JOIN public.practices AS pc ON pc.id = sr.practice_id
  WHERE sr.user_id = v_user
    AND sr.practice_id = p_practice_id
    AND sr.is_active = true
    AND pc.account_status = 'active'
    AND (
      sr.location_id IS NULL
      OR sr.location_id = p_location_id
      OR (sr.role = 'practitioner' AND sr.practitioner_id = p_practitioner_id)
    )
    AND (
      sr.role <> 'practitioner'
      OR sr.practitioner_id = p_practitioner_id
    )
  ORDER BY CASE sr.role
    WHEN 'practice_administrator' THEN 1
    WHEN 'receptionist' THEN 2
    WHEN 'practitioner' THEN 3
    ELSE 4 END
  LIMIT 1;

  v_is_atlas_admin := public.is_atlas_admin();

  IF v_role IS NULL AND NOT v_is_atlas_admin THEN
    RAISE EXCEPTION 'You do not have permission to book at this practice or location'
      USING ERRCODE = '42501';
  END IF;

  IF p_is_emergency AND (
    NULLIF(btrim(p_reason), '') IS NULL
    OR (v_role NOT IN ('receptionist', 'practice_administrator') AND NOT v_is_atlas_admin)
  ) THEN
    RAISE EXCEPTION 'An emergency booking requires an authorized staff role and a reason'
      USING ERRCODE = '42501';
  END IF;

  IF p_allow_overlap AND (
    NOT p_is_emergency
    OR NULLIF(btrim(p_override_reason), '') IS NULL
    OR (v_role NOT IN ('receptionist', 'practice_administrator') AND NOT v_is_atlas_admin)
  ) THEN
    RAISE EXCEPTION 'An emergency overlap override requires an authorized staff role and a reason'
      USING ERRCODE = '42501';
  END IF;

  IF p_allow_overlap AND NOT p_is_emergency THEN
    RAISE EXCEPTION 'Overlap is allowed only for an emergency booking'
      USING ERRCODE = '22023';
  END IF;

  SELECT pr.appointment_duration_minutes, pr.name, lo.name
    INTO v_duration, v_practitioner_name, v_location_name
  FROM public.practitioners AS pr
  JOIN public.practices AS pc ON pc.id = pr.practice_id
  JOIN public.locations AS lo ON lo.id = p_location_id
  WHERE pr.id = p_practitioner_id
    AND pr.practice_id = p_practice_id
    AND pr.location_id = p_location_id
    AND pr.is_active = true
    AND pc.account_status = 'active'
    AND lo.practice_id = p_practice_id
    AND lo.is_active = true
  FOR SHARE OF pr, pc, lo;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'The selected practitioner, location, or practice is inactive'
      USING ERRCODE = '22023';
  END IF;

  v_duration := COALESCE(v_duration, 30);
  IF v_duration < 1 OR v_duration > 480 THEN
    RAISE EXCEPTION 'The practitioner appointment duration is invalid'
      USING ERRCODE = '22023';
  END IF;

  -- Ordinary staff bookings must fit configured hours. An explicitly marked
  -- emergency may bypass hours, but still needs a reason and scoped permission.
  IF NOT p_is_emergency AND NOT EXISTS (
    SELECT 1
    FROM public.practitioner_availability AS av
    WHERE av.practitioner_id = p_practitioner_id
      AND av.day_of_week = EXTRACT(DOW FROM p_appointment_date)::integer
      AND p_appointment_time >= av.start_time
      AND p_appointment_time + make_interval(mins => v_duration) <= av.end_time
  ) THEN
    RAISE EXCEPTION 'The selected time is outside the practitioner''s available hours'
      USING ERRCODE = '22023';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_practitioner_id::text),
    pg_catalog.hashtext(p_appointment_date::text)
  );

  v_start := p_appointment_date + p_appointment_time;

  SELECT EXISTS (
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
  ) INTO v_has_overlap;

  IF v_has_overlap AND NOT p_allow_overlap THEN
    RAISE EXCEPTION 'That time overlaps another appointment. Choose another time or use the authorized emergency override.'
      USING ERRCODE = '23P01';
  END IF;

  IF p_patient_id IS NOT NULL THEN
    SELECT pt.first_name, pt.surname
      INTO v_first, v_surname
    FROM public.patients AS pt
    WHERE pt.id = p_patient_id
      AND pt.practice_id = p_practice_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'The selected patient does not belong to this practice'
        USING ERRCODE = '22023';
    END IF;
    v_patient_id := p_patient_id;
  ELSE
    IF NULLIF(btrim(p_first_name), '') IS NULL
       OR NULLIF(btrim(p_surname), '') IS NULL
       OR NULLIF(btrim(p_email), '') IS NULL
       OR NULLIF(btrim(p_mobile_number), '') IS NULL
       OR length(btrim(p_first_name)) > 100
       OR length(btrim(p_surname)) > 100
       OR length(btrim(p_email)) > 254
       OR length(btrim(p_mobile_number)) > 40 THEN
      RAISE EXCEPTION 'Please provide the new patient name and contact details'
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.patients (
      practice_id, first_name, surname, email, mobile_number
    )
    VALUES (
      p_practice_id, btrim(p_first_name), btrim(p_surname),
      btrim(p_email), btrim(p_mobile_number)
    )
    RETURNING id, first_name, surname INTO v_patient_id, v_first, v_surname;
  END IF;

  INSERT INTO public.appointments (
    practice_id, location_id, practitioner_id, patient_id,
    appointment_date, appointment_time, duration_minutes, reason,
    status, is_emergency
  )
  VALUES (
    p_practice_id, p_location_id, p_practitioner_id,
    v_patient_id, p_appointment_date, p_appointment_time,
    v_duration, NULLIF(btrim(p_reason), ''), 'booked', COALESCE(p_is_emergency, false)
  )
  RETURNING id INTO v_appointment_id;

  INSERT INTO public.appointment_timeline (appointment_id, event_text)
  VALUES (
    v_appointment_id,
    CASE
      WHEN p_allow_overlap THEN 'Emergency overlap override by authenticated staff. Reason: ' || btrim(p_override_reason)
      WHEN p_is_emergency THEN 'Emergency / walk-in booking by authenticated staff. Reason: ' || COALESCE(NULLIF(btrim(p_reason), ''), 'Not provided')
      ELSE 'Appointment booked by authenticated staff'
    END
  );

  RETURN QUERY
  SELECT v_appointment_id, v_patient_id, v_first, v_surname,
         v_practitioner_name, v_location_name, p_appointment_date,
         p_appointment_time, COALESCE(p_is_emergency, false);
END;
$function$;

REVOKE ALL ON FUNCTION public.create_staff_booking(uuid, uuid, uuid, date, time without time zone, uuid, text, text, text, text, text, boolean, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_staff_booking(uuid, uuid, uuid, date, time without time zone, uuid, text, text, text, text, text, boolean, boolean, text) TO authenticated;
