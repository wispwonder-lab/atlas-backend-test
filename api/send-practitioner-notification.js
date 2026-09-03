import webpush from 'web-push';

webpush.setVapidDetails(
  process.env.VAPID_SUBJECT,
  process.env.VAPID_PUBLIC_KEY,
  process.env.VAPID_PRIVATE_KEY
);

const SUPABASE_URL = 'https://ppffrufhxitjpebkexjz.supabase.co';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { practitionerUserId, title, body } = req.body || {};
  if (!practitionerUserId || !title || !body) {
    return res.status(400).json({ error: 'practitionerUserId, title and body are required.' });
  }

  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceKey) {
    return res.status(500).json({ error: 'SUPABASE_SERVICE_ROLE_KEY is not set on the server.' });
  }

  try {
    const listUrl = SUPABASE_URL + '/rest/v1/push_subscriptions?user_id=eq.' + practitionerUserId + '&select=endpoint,p256dh,auth_key';
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

    return res.status(200).json({ sent, failed, errors });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
}
