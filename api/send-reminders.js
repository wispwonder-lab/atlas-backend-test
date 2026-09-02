const SUPABASE_URL = 'https://ppffrufhxitjpebkexjz.supabase.co';

function getTomorrowSAST(){
  const now = new Date();
  const sast = new Date(now.getTime() + 2 * 60 * 60 * 1000); // shift to SAST wall-clock instant
  sast.setUTCDate(sast.getUTCDate() + 1);
  const y = sast.getUTCFullYear();
  const m = String(sast.getUTCMonth() + 1).padStart(2, '0');
  const d = String(sast.getUTCDate()).padStart(2, '0');
  return y + '-' + m + '-' + d;
}

export default async function handler(req, res) {
  const authHeader = req.headers.authorization;
  const querySecret = req.query.secret;
  const expected = 'Bearer ' + process.env.CRON_SECRET;
  if(authHeader !== expected && querySecret !== process.env.CRON_SECRET){
    return res.status(401).json({ error: 'Unauthorized' });
  }

  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!serviceKey || !process.env.RESEND_API_KEY){
    return res.status(500).json({ error: 'Required environment variables are not set.' });
  }

  const tomorrow = getTomorrowSAST();

  try {
    const listUrl = SUPABASE_URL + '/rest/v1/appointments'
      + '?appointment_date=eq.' + tomorrow
      + '&status=eq.booked'
      + '&reminder_sent_at=is.null'
      + '&select=id,appointment_time,patients(first_name,email),practitioners(name),locations(name)';

    const listResp = await fetch(listUrl, {
      headers: { apikey: serviceKey, Authorization: 'Bearer ' + serviceKey }
    });
    const appointments = await listResp.json();
    if(!listResp.ok){
      return res.status(500).json({ error: 'Could not load appointments.', detail: appointments });
    }

    let sent = 0, failed = 0;
    const errors = [];

    for(const appt of appointments){
      const patient = appt.patients;
      if(!patient || !patient.email){ failed++; errors.push({ id: appt.id, error: 'No patient email' }); continue; }

      const time = (appt.appointment_time || '').slice(0,5);
      const practitionerName = appt.practitioners ? appt.practitioners.name : 'your practitioner';
      const locationName = appt.locations ? appt.locations.name : '';

      const html = '<div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;color:#1E293B;">'
        + '<h2 style="color:#2563EB;">Appointment reminder</h2>'
        + '<p>Hi ' + patient.first_name + ',</p>'
        + '<p>Just a reminder — your appointment is tomorrow:</p>'
        + '<p style="background:#F8FAFC;border:1px solid #E2E8F0;border-radius:8px;padding:16px;">'
        + '<strong>' + practitionerName + '</strong><br>'
        + (locationName ? locationName + '<br>' : '')
        + tomorrow + ' at ' + time
        + '</p><p>See you then.</p></div>';

      const sendResp = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: { 'Authorization': 'Bearer ' + process.env.RESEND_API_KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          from: 'Atlas <onboarding@resend.dev>',
          to: [patient.email],
          subject: 'Reminder: your appointment is tomorrow',
          html
        })
      });

      if(!sendResp.ok){
        const sendErrorBody = await sendResp.json().catch(() => ({}));
        failed++; errors.push({ id: appt.id, error: 'Resend rejected the email', detail: sendErrorBody }); continue;
      }

      const markResp = await fetch(SUPABASE_URL + '/rest/v1/appointments?id=eq.' + appt.id, {
        method: 'PATCH',
        headers: {
          apikey: serviceKey, Authorization: 'Bearer ' + serviceKey,
          'Content-Type': 'application/json', 'Prefer': 'return=minimal'
        },
        body: JSON.stringify({ reminder_sent_at: new Date().toISOString() })
      });
      if(!markResp.ok){ failed++; errors.push({ id: appt.id, error: 'Sent but could not mark as reminded' }); continue; }

      sent++;
    }

    return res.status(200).json({ tomorrow, total: appointments.length, sent, failed, errors });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
}
