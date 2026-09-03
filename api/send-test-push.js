import webpush from 'web-push';

const SUPABASE_URL = 'https://ppffrufhxitjpebkexjz.supabase.co';

webpush.setVapidDetails(
  process.env.VAPID_SUBJECT,
  process.env.VAPID_PUBLIC_KEY,
  process.env.VAPID_PRIVATE_KEY
);

export default async function handler(req, res) {
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (
    !serviceKey ||
    !process.env.VAPID_SUBJECT ||
    !process.env.VAPID_PUBLIC_KEY ||
    !process.env.VAPID_PRIVATE_KEY
  ) {
    return res.status(500).json({
      error: 'Required environment variables are not set.'
    });
  }

  try {
    const subscriptionResp = await fetch(
      SUPABASE_URL
        + '/rest/v1/push_subscriptions'
        + '?select=id,endpoint,p256dh,auth_key,created_at'
        + '&order=created_at.desc'
        + '&limit=1',
      {
        headers: {
          apikey: serviceKey,
          Authorization: 'Bearer ' + serviceKey
        }
      }
    );

    const subscriptions = await subscriptionResp.json();

    if (!subscriptionResp.ok) {
      return res.status(500).json({
        error: 'Could not load push subscription.'
      });
    }

    if (!subscriptions || subscriptions.length === 0) {
      return res.status(404).json({
        error: 'No push subscription found.'
      });
    }

    const saved = subscriptions[0];

    const subscription = {
      endpoint: saved.endpoint,
      keys: {
        p256dh: saved.p256dh,
        auth: saved.auth_key
      }
    };

    await webpush.sendNotification(
      subscription,
      JSON.stringify({
        title: 'Appointment update',
        body: 'Push notifications are working! 🎉',
        icon: '/icon-192.png'
      })
    );

    return res.status(200).json({
      success: true,
      message: 'Push notification sent.'
    });
  } catch (error) {
    console.error('Push notification error:', error);

    return res.status(500).json({
      error: 'Could not send push notification.',
      detail: error.message
    });
  }
}
