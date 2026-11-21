const SUPABASE_URL = 'https://ppffrufhxitjpebkexjz.supabase.co';

function escapeHtml(value) {
  return String(value == null ? '' : value).replace(/[&<>"']/g, ch => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  })[ch]);
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { appointmentId } = req.body || {};
  if (!appointmentId || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(appointmentId)) {
    return res.status(400).json({ error: 'A valid appointmentId is required.' });
  }

  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const resendKey = process.env.RESEND_API_KEY;
  if (!serviceKey || !resendKey) {
    return res.status(500).json({ error: 'Required email service configuration is missing.' });
  }

  const headers = { apikey: serviceKey, Authorization: 'Bearer ' + serviceKey };

  try {
    const lookupUrl = SUPABASE_URL + '/rest/v1/appointments?id=eq.' + encodeURIComponent(appointmentId)
      + '&select=id,status,appointment_date,appointment_time,confirmation_sent_at,patients(first_name,email),practitioners(name),locations(name),practices(name)&limit=1';
    const lookupResp = await fetch(lookupUrl, { headers });
    const rows = await lookupResp.json();
    if (!lookupResp.ok) return res.status(500).json({ error: 'Could not load the booking details.' });
    if (!rows || rows.length === 0) return res.status(404).json({ error: 'Appointment not found.' });

    const appt = rows[0];
    const status = String(appt.status || '').toLowerCase();
    if (['cancelled', 'canceled', 'no-show', 'noshow'].includes(status)) {
      return res.status(409).json({ error: 'This appointment is no longer active.' });
    }
    if (appt.confirmation_sent_at) {
      return res.status(200).json({ success: true, alreadySent: true });
    }

    const patient = appt.patients;
    if (!patient || !patient.email) return res.status(422).json({ error: 'No email address is saved for this patient.' });

    // Claim this appointment before sending so repeated public requests cannot
    // trigger duplicate confirmation emails.
    const claimResp = await fetch(
      SUPABASE_URL + '/rest/v1/appointments?id=eq.' + encodeURIComponent(appointmentId) + '&confirmation_sent_at=is.null',
      {
        method: 'PATCH',
        headers: { ...headers, 'Content-Type': 'application/json', Prefer: 'return=representation' },
        body: JSON.stringify({ confirmation_sent_at: new Date().toISOString() })
      }
    );
    const claimed = await claimResp.json();
    if (!claimResp.ok) return res.status(500).json({ error: 'Could not reserve the confirmation email.' });
    if (!claimed || claimed.length === 0) return res.status(200).json({ success: true, alreadySent: true });

    const practitionerName = appt.practitioners ? appt.practitioners.name : 'your practitioner';
    const locationName = appt.locations ? appt.locations.name : '';
    const practiceName = appt.practices ? appt.practices.name : 'Atlas';
    const dateLabel = new Date(appt.appointment_date + 'T12:00:00').toLocaleDateString('en-ZA', {
      weekday: 'long', day: 'numeric', month: 'long', year: 'numeric'
    });
    const time = String(appt.appointment_time || '').slice(0, 5);

    const html = '<div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;color:#1E293B;">'
      + '<h2 style="color:#2563EB;">You\'re all set!</h2>'
      + '<p>Hi ' + escapeHtml(patient.first_name) + ',</p>'
      + '<p>Your appointment at ' + escapeHtml(practiceName) + ' is confirmed:</p>'
      + '<p style="background:#F8FAFC;border:1px solid #E2E8F0;border-radius:8px;padding:16px;">'
      + '<strong>' + escapeHtml(practitionerName) + '</strong><br>'
      + (locationName ? escapeHtml(locationName) + '<br>' : '')
      + escapeHtml(dateLabel) + ' at ' + escapeHtml(time)
      + '</p><p>See you then.</p>'
      + '<p style="color:#64748B;font-size:13px;">If you did not make this booking, please contact the practice.</p></div>';

    const sendResp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + resendKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: 'Atlas <onboarding@resend.dev>',
        to: [patient.email],
        subject: 'Your appointment is confirmed',
        html
      })
    });
    const sendData = await sendResp.json().catch(() => ({}));

    if (!sendResp.ok) {
      await fetch(SUPABASE_URL + '/rest/v1/appointments?id=eq.' + encodeURIComponent(appointmentId), {
        method: 'PATCH',
        headers: { ...headers, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
        body: JSON.stringify({ confirmation_sent_at: null })
      });
      return res.status(502).json({ error: sendData.message || 'The email provider rejected the confirmation.' });
    }

    return res.status(200).json({ success: true, id: sendData.id });
  } catch (err) {
    return res.status(500).json({ error: 'Could not send the booking confirmation.' });
  }
}
