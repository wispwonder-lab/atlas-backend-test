-- Limit helper-function RPC access to signed-in staff.
-- These helpers remain callable by authenticated RLS policies; they are not
-- intended as anonymous public API endpoints. get_queue_status remains public
-- by design because patients use one-time queue tokens.
REVOKE ALL ON FUNCTION public.is_active_staff_at(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_active_staff_at(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.is_atlas_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_atlas_admin() TO authenticated;

REVOKE ALL ON FUNCTION public.is_practice_admin_of(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_practice_admin_of(uuid) TO authenticated;
