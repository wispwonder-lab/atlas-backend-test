-- Atlas phase 1c: enforce active-practice status on authenticated staff data access.
-- Public booking table policies are intentionally left for the coordinated cutover.

CREATE OR REPLACE FUNCTION public.is_active_staff_at(target_practice_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff_roles AS sr
    JOIN public.practices AS pc ON pc.id = sr.practice_id
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = target_practice_id
      AND sr.is_active = true
      AND pc.account_status = 'active'
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_practice_admin_of(target_practice_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff_roles AS sr
    JOIN public.practices AS pc ON pc.id = sr.practice_id
    WHERE sr.user_id = auth.uid()
      AND sr.role = 'practice_administrator'
      AND sr.practice_id = target_practice_id
      AND sr.is_active = true
      AND pc.account_status = 'active'
  );
$function$;

DROP POLICY IF EXISTS "Staff can create appointments at their scoped location" ON public.appointments;
CREATE POLICY "Staff can create appointments at their scoped location"
ON public.appointments FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    JOIN public.practices AS pc ON pc.id = sr.practice_id
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = appointments.practice_id
      AND sr.is_active = true
      AND pc.account_status = 'active'
      AND (sr.location_id IS NULL OR sr.location_id = appointments.location_id)
  )
);

DROP POLICY IF EXISTS "Staff can update their scoped appointments" ON public.appointments;
CREATE POLICY "Staff can update their scoped appointments"
ON public.appointments FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    JOIN public.practices AS pc ON pc.id = sr.practice_id
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = appointments.practice_id
      AND sr.is_active = true
      AND pc.account_status = 'active'
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = appointments.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = appointments.practitioner_id)
      )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    JOIN public.practices AS pc ON pc.id = sr.practice_id
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = appointments.practice_id
      AND sr.is_active = true
      AND pc.account_status = 'active'
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = appointments.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = appointments.practitioner_id)
      )
  )
);

DROP POLICY IF EXISTS "Staff can view their practice's appointments" ON public.appointments;
CREATE POLICY "Staff can view their practice's appointments"
ON public.appointments FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    JOIN public.practices AS pc ON pc.id = sr.practice_id
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = appointments.practice_id
      AND sr.is_active = true
      AND pc.account_status = 'active'
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = appointments.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = appointments.practitioner_id)
      )
  )
);

DROP POLICY IF EXISTS "Staff can create patients for their practice" ON public.patients;
CREATE POLICY "Staff can create patients for their practice"
ON public.patients FOR INSERT TO authenticated
WITH CHECK (public.is_active_staff_at(practice_id));

DROP POLICY IF EXISTS "Staff can view their practice's patients" ON public.patients;
CREATE POLICY "Staff can view their practice's patients"
ON public.patients FOR SELECT TO authenticated
USING (public.is_active_staff_at(practice_id));

DROP POLICY IF EXISTS "Staff can add to their practice's appointment timeline" ON public.appointment_timeline;
CREATE POLICY "Staff can add to their practice's appointment timeline"
ON public.appointment_timeline FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.appointments AS a
    JOIN public.practices AS pc ON pc.id = a.practice_id
    JOIN public.staff_roles AS sr ON sr.practice_id = a.practice_id
    WHERE a.id = appointment_timeline.appointment_id
      AND sr.user_id = auth.uid()
      AND sr.is_active = true
      AND pc.account_status = 'active'
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = a.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = a.practitioner_id)
      )
  )
);

DROP POLICY IF EXISTS "Staff can view their practice's appointment timeline" ON public.appointment_timeline;
CREATE POLICY "Staff can view their practice's appointment timeline"
ON public.appointment_timeline FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.appointments AS a
    JOIN public.practices AS pc ON pc.id = a.practice_id
    JOIN public.staff_roles AS sr ON sr.practice_id = a.practice_id
    WHERE a.id = appointment_timeline.appointment_id
      AND sr.user_id = auth.uid()
      AND sr.is_active = true
      AND pc.account_status = 'active'
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = a.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = a.practitioner_id)
      )
  )
);

DROP POLICY IF EXISTS "Staff can view their practice's locations" ON public.locations;
CREATE POLICY "Staff can view their practice's locations"
ON public.locations FOR SELECT TO authenticated
USING (
  public.is_active_staff_at(practice_id)
  AND EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = locations.practice_id
      AND sr.is_active = true
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = locations.id))
        OR (sr.role = 'practitioner' AND EXISTS (
          SELECT 1 FROM public.practitioners AS p
          WHERE p.id = sr.practitioner_id AND p.location_id = locations.id
        ))
      )
  )
);

DROP POLICY IF EXISTS "Staff can view availability for their scoped practitioners" ON public.practitioner_availability;
CREATE POLICY "Staff can view availability for their scoped practitioners"
ON public.practitioner_availability FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.practitioners AS p
    WHERE p.id = practitioner_availability.practitioner_id
      AND public.is_active_staff_at(p.practice_id)
      AND EXISTS (
        SELECT 1 FROM public.staff_roles AS sr
        WHERE sr.user_id = auth.uid()
          AND sr.practice_id = p.practice_id
          AND sr.is_active = true
          AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = p.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = p.id)
      )
      )
  )
);

DROP POLICY IF EXISTS "Staff can view their scoped practitioners" ON public.practitioners;
CREATE POLICY "Staff can view their scoped practitioners"
ON public.practitioners FOR SELECT TO authenticated
USING (
  public.is_active_staff_at(practice_id)
  AND EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = practitioners.practice_id
      AND sr.is_active = true
      AND (sr.location_id IS NULL OR sr.location_id = practitioners.location_id
           OR (sr.role = 'practitioner' AND sr.practitioner_id = practitioners.id))
  )
);

DROP POLICY IF EXISTS "Staff can create queue entries at their scoped location" ON public.queue_entries;
CREATE POLICY "Staff can create queue entries at their scoped location"
ON public.queue_entries FOR INSERT TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = queue_entries.practice_id
      AND sr.is_active = true
      AND public.is_active_staff_at(sr.practice_id)
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = queue_entries.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = queue_entries.practitioner_id)
      )
  )
);

DROP POLICY IF EXISTS "Staff can update their scoped queue entries" ON public.queue_entries;
CREATE POLICY "Staff can update their scoped queue entries"
ON public.queue_entries FOR UPDATE TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = queue_entries.practice_id
      AND sr.is_active = true
      AND public.is_active_staff_at(sr.practice_id)
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = queue_entries.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = queue_entries.practitioner_id)
      )
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = queue_entries.practice_id
      AND sr.is_active = true
      AND public.is_active_staff_at(sr.practice_id)
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = queue_entries.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = queue_entries.practitioner_id)
      )
  )
);

DROP POLICY IF EXISTS "Staff can view their scoped queue entries" ON public.queue_entries;
CREATE POLICY "Staff can view their scoped queue entries"
ON public.queue_entries FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.staff_roles AS sr
    WHERE sr.user_id = auth.uid()
      AND sr.practice_id = queue_entries.practice_id
      AND sr.is_active = true
      AND public.is_active_staff_at(sr.practice_id)
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = queue_entries.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = queue_entries.practitioner_id)
      )
  )
);

DROP POLICY IF EXISTS "Staff can record override events at their practice" ON public.queue_override_events;
CREATE POLICY "Staff can record override events at their practice"
ON public.queue_override_events FOR INSERT TO authenticated
WITH CHECK (
  overridden_by = auth.uid()
  AND EXISTS (
    SELECT 1 FROM public.queue_entries AS qe
    JOIN public.staff_roles AS sr ON sr.practice_id = qe.practice_id
    WHERE qe.id = queue_override_events.queue_entry_id
      AND sr.user_id = auth.uid()
      AND sr.is_active = true
      AND public.is_active_staff_at(sr.practice_id)
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = qe.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = qe.practitioner_id)
      )
  )
);

DROP POLICY IF EXISTS "Staff can view override events at their practice" ON public.queue_override_events;
CREATE POLICY "Staff can view override events at their practice"
ON public.queue_override_events FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.queue_entries AS qe
    JOIN public.staff_roles AS sr ON sr.practice_id = qe.practice_id
    WHERE qe.id = queue_override_events.queue_entry_id
      AND sr.user_id = auth.uid()
      AND sr.is_active = true
      AND public.is_active_staff_at(sr.practice_id)
      AND (
        (sr.role <> 'practitioner' AND (sr.location_id IS NULL OR sr.location_id = qe.location_id))
        OR (sr.role = 'practitioner' AND sr.practitioner_id = qe.practitioner_id)
      )
  )
);
