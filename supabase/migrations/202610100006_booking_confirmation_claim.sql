-- Claim public booking confirmation emails once per appointment.
-- The API marks the claim before sending to prevent duplicate-trigger spam.
ALTER TABLE public.appointments
  ADD COLUMN IF NOT EXISTS confirmation_email_claimed_at timestamptz;

-- Keep cancellation push notifications idempotent as well.
ALTER TABLE public.appointments
  ADD COLUMN IF NOT EXISTS cancellation_notification_claimed_at timestamptz;
