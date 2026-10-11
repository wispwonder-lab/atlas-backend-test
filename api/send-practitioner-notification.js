import webpush from 'web-push';

const SUPABASE_URL = 'https://ppffrufhxitjpebkexjz.supabase.co';
const SUPABASE_PUBLIC_KEY = process.env.SUPABASE_ANON_KEY || 'sb_publishable_yQwm3d09oQ53pMPH9kPefA_XxGqt3rg';

function validUuid(value) {
  return typeof value === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const authorization = req.headers.authorization || '';
  const tokenMatch = authorization.match(/^Bearer\s+(.+)$/i);
  if (!tokenMatch) return res.status(401).json({ error: 'Sign-in is required.' });

  const appointmentId = req.body?.appointmentId;
  if (!validUuid(appointmentId)) return res.status(400).json({ error: 'A valid appointment identifier is required.' });

  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const missing = [];
  if (!process.env.VAPID_SUBJECT) missing.push('VAPID_SUBJECT');
  if (!process.env.VAPID_PUBLIC_KEY) missing.push('VAPID_PUBLIC_KEY');
  if (!process.env.VAPID_PRIVATE_KEY) missing.push('VAPID_PRIVATE_KEY');
  if (!serviceKey) missing.push('SUPABASE_SERVICE_ROLE_KEY');
  if (!SUPABASE_PUBLIC_KEY) missing.push('SUPABASE_ANON_KEY');
  if (missing.length) return res.status(500).json({ error: 'Push notifications are not configured.' });

  try {
    // Validate the caller's Supabase access token rather than trusting a
    // client-supplied practitioner ID or arbitrary push message.
    const authResponse = await fetch(SUPABASE_URL + '/auth/v1/user', {
      headers: { apikey: SUPABASE_PUBLIC_KEY, Authorization: 'Bearer ' + tokenMatch[1] }
    });
    if (!authResponse.ok) return res.status(401).json({ error: 'Your session is invalid or expired.' });
    const caller = await authResponse.json();
    if (!caller?.id) return res.status(401).json({ error: 'Your session is invalid or expired.' });

    const restHeaders = { apikey: serviceKey, Authorization: 'Bearer ' + serviceKey };
    const appointmentResponse = await fetch(
      SUPABASE_URL + '/rest/v1/appointments?id=eq.' + encodeURIComponent(appointmentId)
        + '&select=id,practice_id,location_id,practitioner_id,appointment_date,appointment_time,status,practitioners(name),patients(first_name,surname)',
      { headers: restHeaders }
    );
    const appointmentRows = await appointmentResponse.json();
    if (!appointmentResponse.ok || !Array.isArray(appointmentRows)) {
      return res.status(500).json({ error: 'Could not verify the appointment.' });
    }
    const appointment = appointmentRows[0];
    if (!appointment || String(appointment.status || '').toLowerCase() !== 'cancelled') {
      return res.status(409).json({ error: 'Only a cancelled appointment can trigger this notification.' });
    }

    const callerRolesResponse = await fetch(
      SUPABASE_URL + '/rest/v1/staff_roles?user_id=eq.' + encodeURIComponent(caller.id)
        + '&practice_id=eq.' + encodeURIComponent(appointment.practice_id)
        + '&is_active=eq.true&select=role,location_id,practitioner_id',
      { headers: restHeaders }
    );
    const callerRoles = await callerRolesResponse.json();
    if (!callerRolesResponse.ok || !Array.isArray(callerRoles)) {
      return res.status(500).json({ error: 'Could not verify staff permissions.' });
    }
    const permitted = callerRoles.some((role) =>
      ['atlas_administrator', 'practice_administrator', 'receptionist'].includes(role.role)
      && (!role.location_id || role.location_id === appointment.location_id)
    );
    if (!permitted) return res.status(403).json({ error: 'You do not have permission to notify staff for this practice.' });

    const practitionerRolesResponse = await fetch(
      SUPABASE_URL + '/rest/v1/staff_roles?practitioner_id=eq.' + encodeURIComponent(appointment.practitioner_id)
        + '&role=eq.practitioner&is_active=eq.true&select=user_id',
      { headers: restHeaders }
    );
    const practitionerRoles = await practitionerRolesResponse.json();
    if (!practitionerRolesResponse.ok || !Array.isArray(practitionerRoles)) {
      return res.status(500).json({ error: 'Could not find the practitioner notification target.' });
    }
    const practitionerUserIds = [...new Set(practitionerRoles.map((r) => r.user_id).filter(Boolean))];
    if (!practitionerUserIds.length) return res.status(200).json({ sent: 0 });

    const vapidSubject = process.env.VAPID_SUBJECT;
    if (!/^mailto:|^https?:/.test(vapidSubject)) {
      return res.status(500).json({ error: 'Push notification configuration is invalid.' });
    }
    webpush.setVapidDetails(vapidSubject, process.env.VAPID_PUBLIC_KEY, process.env.VAPID_PRIVATE_KEY);

    const patient = appointment.patients;
    const practitioner = appointment.practitioners;
    const patientName = [patient?.first_name, patient?.surname].filter(Boolean).join(' ') || 'A patient';
    const date = appointment.appointment_date;
    const time = String(appointment.appointment_time || '').slice(0, 5);
    const payload = JSON.stringify({
      title: 'Appointment cancelled',
      body: patientName + "'s appointment on " + date + ' at ' + time + ' was cancelled.'
    });

    let sent = 0;
    let failed = 0;
    for (const userId of practitionerUserIds) {
      const subscriptionsResponse = await fetch(
        SUPABASE_URL + '/rest/v1/push_subscriptions?user_id=eq.' + encodeURIComponent(userId)
          + '&select=endpoint,p256dh,auth_key',
        { headers: restHeaders }
      );
      const subscriptions = await subscriptionsResponse.json();
      if (!subscriptionsResponse.ok || !Array.isArray(subscriptions)) {
        failed++;
        continue;
      }
      for (const sub of subscriptions) {
        try {
          await webpush.sendNotification({
            endpoint: sub.endpoint,
            keys: { p256dh: sub.p256dh, auth: sub.auth_key }
          }, payload);
          sent++;
        } catch (error) {
          failed++;
          if (error.statusCode === 404 || error.statusCode === 410) {
            await fetch(SUPABASE_URL + '/rest/v1/push_subscriptions?endpoint=eq.' + encodeURIComponent(sub.endpoint), {
              method: 'DELETE', headers: restHeaders
            });
          }
        }
      }
    }
    return res.status(200).json({ sent, failed });
  } catch {
    return res.status(500).json({ error: 'The push notification service encountered an error.' });
  }
}
