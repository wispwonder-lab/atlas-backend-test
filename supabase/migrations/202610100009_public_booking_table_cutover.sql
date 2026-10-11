-- Final public-table cutover for the patient-booking flow.
-- Apply only after get_public_booking_directory, get_public_booked_slots, and
-- create_public_booking are deployed and the frontend calls those RPCs.
-- Patient booking remains anonymous through the narrowly scoped RPCs.

DROP POLICY IF EXISTS "Public can view practices" ON public.practices;
DROP POLICY IF EXISTS "Public can view active locations" ON public.locations;
DROP POLICY IF EXISTS "Public can view available practitioners" ON public.practitioners;
DROP POLICY IF EXISTS "Public can view practitioner availability" ON public.practitioner_availability;
DROP POLICY IF EXISTS "Public can view appointment times for availability checking" ON public.appointments;
DROP POLICY IF EXISTS "Public can create an appointment" ON public.appointments;
DROP POLICY IF EXISTS "Public can create a patient record" ON public.patients;
DROP POLICY IF EXISTS "Public can create a timeline entry" ON public.appointment_timeline;

-- Direct REST table access is not needed by anonymous booking after the RPC
-- cutover. Explicit authenticated staff grants are left intact.
REVOKE ALL ON TABLE
  public.practices,
  public.locations,
  public.practitioners,
  public.practitioner_availability,
  public.appointments,
  public.patients,
  public.appointment_timeline
FROM PUBLIC, anon;
