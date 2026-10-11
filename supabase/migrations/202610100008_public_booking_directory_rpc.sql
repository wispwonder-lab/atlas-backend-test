-- Return only the fields needed by the anonymous patient-booking page.
-- SECURITY DEFINER is intentional: the client must not receive direct table reads.
CREATE OR REPLACE FUNCTION public.get_public_booking_directory(p_practice_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_practice_id uuid;
  v_practice_name text;
  v_locations jsonb;
  v_practitioners jsonb;
BEGIN
  IF NULLIF(btrim(p_practice_name), '') IS NULL OR length(btrim(p_practice_name)) > 160 THEN
    RAISE EXCEPTION 'Invalid practice request' USING ERRCODE = '22023';
  END IF;

  SELECT pc.id, pc.name
    INTO v_practice_id, v_practice_name
  FROM public.practices AS pc
  WHERE lower(pc.name) = lower(btrim(p_practice_name))
    AND pc.account_status = 'active'
  ORDER BY pc.created_at
  LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN jsonb_build_object(
      'practice', NULL,
      'locations', '[]'::jsonb,
      'practitioners', '[]'::jsonb
    );
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', lo.id, 'name', lo.name)
                            ORDER BY lo.name), '[]'::jsonb)
    INTO v_locations
  FROM public.locations AS lo
  WHERE lo.practice_id = v_practice_id
    AND lo.is_active = true;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', pr.id,
      'name', pr.name,
      'role', pr.role,
      'location_id', pr.location_id,
      'appointment_duration_minutes', COALESCE(pr.appointment_duration_minutes, 30),
      'availability', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'day_of_week', av.day_of_week,
          'start_time', av.start_time,
          'end_time', av.end_time
        ) ORDER BY av.day_of_week, av.start_time)
        FROM public.practitioner_availability AS av
        WHERE av.practitioner_id = pr.id
      ), '[]'::jsonb)
    ) ORDER BY pr.name
  ), '[]'::jsonb)
    INTO v_practitioners
  FROM public.practitioners AS pr
  JOIN public.locations AS lo ON lo.id = pr.location_id
  WHERE pr.practice_id = v_practice_id
    AND lo.practice_id = v_practice_id
    AND lo.is_active = true
    AND pr.is_active = true
    AND pr.is_available = true;

  RETURN jsonb_build_object(
    'practice', jsonb_build_object('id', v_practice_id, 'name', v_practice_name),
    'locations', v_locations,
    'practitioners', v_practitioners
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_public_booking_directory(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_booking_directory(text) TO anon, authenticated;
