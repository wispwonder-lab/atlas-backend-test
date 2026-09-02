import webpush from 'web-push';

webpush.setVapidDetails(
  process.env.VAPID_SUBJECT,
  process.env.VAPID_PUBLIC_KEY,
  process.env.VAPID_PRIVATE_KEY
);

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { subscription } = req.body || {};

  if (!subscription || !subscription.endpoint || !subscription.keys) {
    return res.status(400).json({
      error: 'A valid push subscription is required.'
    });
  }

  try {
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
