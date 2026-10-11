const SUPABASE_URL = 'https://ppffrufhxitjpebkexjz.supabase.co';

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#39;'
  })[character]);
}

function validEmail(value) {
  return typeof value === 'string'
    && value.length <= 254
    && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const appointmentId = req.body?.appointmentId;
  if (typeof appointmentId !== 'string'
      || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(appointmentId)) {
    return res.status(400).json({ error: 'A valid appointment identifier is required.' });
  }

  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const resendKey = process.env.RESEND_API_KEY;
  if (!serviceKey || !resendKey) {
    return res.status(500).json({ error: 'Booking confirmation service is not configured.' });
  }

  const headers = {
    apikey: serviceKey,
    Authorization: 'Bearer ' + serviceKey,
    'Content-Type': 'application/json'
  };
  const endpoint = SUPABASE_URL + '/rest/v1/appointments';

  try {
    // Atomically claim only an active, unclaimed booking. Repeated calls cannot
    // trigger repeated emails for the same appointment.
    const claimResponse = await fetch(
      endpoint + '?id=eq.' + encodeURIComponent(appointmentId)
        + '&confirmation_email_claimed_at=is.null'
        + '&status=eq.booked&select=id',
      {
        method: 'PATCH',
        headers: { ...headers, Prefer: 'return=representation' },
        body: JSON.stringify({ confirmation_email_claimed_at: new Date().toISOString() })
      }
    );
    const claimed = await claimResponse.json();
    if (!claimResponse.ok) {
      return res.status(500).json({ error: 'Could not verify this booking confirmation.' });
    }
    if (!Array.isArray(claimed) || claimed.length !== 1) {
      // Idempotent response: either not a current booking or already processed.
      return res.status(200).json({ success: true, alreadyProcessed: true });
    }

    const detailsResponse = await fetch(
      endpoint + '?id=eq.' + encodeURIComponent(appointmentId)
        + '&select=id,status,appointment_date,appointment_time,patients(first_name,surname,email),practitioners(name),locations(name)',
      { headers }
    );
    const rows = await detailsResponse.json();
    if (!detailsResponse.ok || !Array.isArray(rows) || rows.length !== 1) {
      await fetch(endpoint + '?id=eq.' + encodeURIComponent(appointmentId), {
        method: 'PATCH', headers,
        body: JSON.stringify({ confirmation_email_claimed_at: null })
      });
      return res.status(500).json({ error: 'Could not load the booking details.' });
    }

    const booking = rows[0];
    const patient = booking.patients;
    const practitioner = booking.practitioners;
    const location = booking.locations;
    const email = patient?.email;
    if (booking.status !== 'booked' || !validEmail(email) || !patient?.first_name || !practitioner?.name) {
      await fetch(endpoint + '?id=eq.' + encodeURIComponent(appointmentId), {
        method: 'PATCH', headers,
        body: JSON.stringify({ confirmation_email_claimed_at: null })
      });
      return res.status(422).json({ error: 'The booking does not have the details needed for confirmation.' });
    }

    const dateLabel = new Intl.DateTimeFormat('en-ZA', {
      dateStyle: 'full',
      timeZone: 'Africa/Johannesburg'
    }).format(new Date(booking.appointment_date + 'T12:00:00+02:00'));
    const timeLabel = String(booking.appointment_time).slice(0, 5);
    const patientName = [patient.first_name, patient.surname].filter(Boolean).join(' ');
    const html = `
      <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;color:#1E293B;">
        <h2 style="color:#2563EB;">Your appointment is confirmed</h2>
        <p>Hi ${escapeHtml(patientName)},</p>
        <p>Your appointment is confirmed:</p>
        <p style="background:#F8FAFC;border:1px solid #E2E8F0;border-radius:8px;padding:16px;">
          <strong>${escapeHtml(practitioner.name)}</strong><br>
          ${location?.name ? escapeHtml(location.name) + '<br>' : ''}
          ${escapeHtml(dateLabel)} at ${escapeHtml(timeLabel)}
        </p>
        <p>See you then.</p>
        <p style="color:#64748B;font-size:13px;">If you didn't make this booking, please contact the practice.</p>
      </div>
    `;

    const sendResponse = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + resendKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: 'Atlas <onboarding@resend.dev>',
        to: [email],
        subject: 'Your appointment is confirmed',
        html
      })
    });
    if (!sendResponse.ok) {
      // Allow a legitimate retry if the provider rejects the email.
      await fetch(endpoint + '?id=eq.' + encodeURIComponent(appointmentId), {
        method: 'PATCH', headers,
        body: JSON.stringify({ confirmation_email_claimed_at: null })
      });
      return res.status(502).json({ error: 'The confirmation email could not be sent.' });
    }

    const result = await sendResponse.json();
    return res.status(200).json({ success: true, id: result.id });
  } catch {
    return res.status(500).json({ error: 'The booking confirmation service encountered an error.' });
  }
}
