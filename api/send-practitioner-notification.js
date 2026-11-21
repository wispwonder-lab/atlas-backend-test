import webpush from 'web-push';

const SUPABASE_URL = 'https://ppffrufhxitjpebkexjz.supabase.co';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();

  // Check every required setting up front, with a real, specific error for
  // whichever one is actually missing or malformed — never a hard crash.
  const missing = [];
  if (!process.env.VAPID_SUBJECT) missing.push('VAPID_SUBJECT');
  if (!process.env.VAPID_PUBLIC_KEY) missing.push('VAPID_PUBLIC_KEY');
  if (!process.env.VAPID_PRIVATE_KEY) missing.push('VAPID_PRIVATE_KEY');
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY) missing.push('SUPABASE_SERVICE_ROLE_KEY');
  if (missing.length > 0) {
    return res.status(500).json({ error: 'Missing required environment variables: ' + missing.join(', ') });
  }
  if (!/^mailto:|^https?:/.test(process.env.VAPID_SUBJECT)) {
    return res.status(500).json({ error: 'VAPID_SUBJECT must start with "mailto:" or "https://". Current value starts with: ' + process.env.VAPID_SUBJECT.slice(0, 15) });
  }

  try {
    webpush.setVapidDetails(
      process.env.VAPID_SUBJECT,
      process.env.VAPID_PUBLIC_KEY,
      process.env.VAPID_PRIVATE_KEY
    );
  } catch (err) {
    return res.status(500).json({ error: 'Could not set up push notifications with the current keys.', detail: err.message });
  }

  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const authHeader = req.headers.authorization || '';
  const accessToken = authHeader.startsWith('Bearer ') ? authHeader.slice(7) : '';
  if (!accessToken) return res.status(401).json({ error: 'Authentication required.' });

  const publicApiKey = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY;
  if (!publicApiKey) return res.status(500).json({ error: 'Supabase public API key is not configured.' });

  const authResp = await fetch(SUPABASE_URL + '/auth/v1/user', {
    headers: { apikey: publicApiKey, Authorization: 'Bearer ' + accessToken }
  });
  if (!authResp.ok) return res.status(401).json({ error: 'Your session is invalid or has expired.' });
  const caller = await authResp.json();

  const { practitionerUserId, title, body } = req.body || {};
  if (!practitionerUserId || !title || !body) {
    return res.status(400).json({ error: 'practitionerUserId, title and body are required.' });
  }

  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceKey) {
    return res.status(500).json({ error: 'SUPABASE_SERVICE_ROLE_KEY is not set on the server.' });
  }

  try {
    const headers = { apikey: serviceKey, Authorization: 'Bearer ' + serviceKey };
    const callerResp = await fetch(
      SUPABASE_URL + '/rest/v1/staff_roles?user_id=eq.' + encodeURIComponent(caller.id)
      + '&is_active=eq.true&role=in.(receptionist,practice_administrator)&select=practice_id,location_id,role',
      { headers }
    );
    const callerRoles = await callerResp.json();
    if (!callerResp.ok) return res.status(500).json({ error: 'Could not verify your practice access.' });

    const targetResp = await fetch(
      SUPABASE_URL + '/rest/v1/staff_roles?user_id=eq.' + encodeURIComponent(practitionerUserId)
      + '&role=eq.practitioner&is_active=eq.true&select=practice_id,practitioner_id',
      { headers }
    );
    const targetRoles = await targetResp.json();
    if (!targetResp.ok) return res.status(500).json({ error: 'Could not verify the practitioner account.' });

    let authorized = false;
    for (const target of targetRoles || []) {
      if (!target.practitioner_id) continue;
      const practitionerResp = await fetch(
        SUPABASE_URL + '/rest/v1/practitioners?id=eq.' + encodeURIComponent(target.practitioner_id)
        + '&select=practice_id,location_id&limit=1',
        { headers }
      );
      const practitionerRows = await practitionerResp.json();
      if (!practitionerResp.ok || !practitionerRows.length) continue;
      const practitioner = practitionerRows[0];
      if (practitioner.practice_id !== target.practice_id) continue;
      if ((callerRoles || []).some(role =>
        role.practice_id === target.practice_id
        && (role.role === 'practice_administrator' || !role.location_id || role.location_id === practitioner.location_id)
      )) {
        authorized = true;
        break;
      }
    }
    if (!authorized) return res.status(403).json({ error: 'You are not authorized to notify this practitioner.' });

    const listUrl = SUPABASE_URL + '/rest/v1/push_subscriptions?user_id=eq.' + encodeURIComponent(practitionerUserId) + '&select=endpoint,p256dh,auth_key';
    const listResp = await fetch(listUrl, {
      headers: { apikey: serviceKey, Authorization: 'Bearer ' + serviceKey }
    });
    const subs = await listResp.json();
    if (!listResp.ok) {
      return res.status(500).json({ error: 'Could not load subscriptions.', detail: subs });
    }
    if (!subs || subs.length === 0) {
      return res.status(200).json({ sent: 0, message: 'This practitioner has no active notification devices.' });
    }

    let sent = 0, failed = 0;
    const errors = [];

    for (const sub of subs) {
      const pushSubscription = {
        endpoint: sub.endpoint,
        keys: { p256dh: sub.p256dh, auth: sub.auth_key }
      };
      try {
        await webpush.sendNotification(pushSubscription, JSON.stringify({ title, body }));
        sent++;
      } catch (err) {
        failed++;
        errors.push({ endpoint: sub.endpoint, error: err.message });
        // A 404/410 means this device unsubscribed or expired — clean it up.
        if (err.statusCode === 404 || err.statusCode === 410) {
          await fetch(SUPABASE_URL + '/rest/v1/push_subscriptions?endpoint=eq.' + encodeURIComponent(sub.endpoint), {
            method: 'DELETE',
            headers: { apikey: serviceKey, Authorization: 'Bearer ' + serviceKey }
          });
        }
      }
    }

    // A 2xx response means at least one push provider accepted the
    // notification. If every device failed, return a failure status so the
    // receptionist can report the problem instead of silently claiming success.
    if (sent === 0 && failed > 0) {
      return res.status(502).json({
        sent,
        failed,
        message: 'The push service rejected the notification for every registered device.',
        errors
      });
    }

    return res.status(200).json({
      sent,
      failed,
      message: failed > 0
        ? 'The notification was accepted by some devices; at least one device failed.'
        : 'The notification was accepted by all registered devices.'
    });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
}
