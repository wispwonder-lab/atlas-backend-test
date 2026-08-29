export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  const { to, patientName, practitionerName, locationName, dateLabel, time } = req.body || {};
  if (!to || !patientName || !practitionerName || !dateLabel || !time) {
    return res.status(400).json({ error: 'Missing required booking details.' });
  }

  if (!process.env.RESEND_API_KEY) {
    return res.status(500).json({ error: 'RESEND_API_KEY is not set on the server.' });
  }

  const html = `
    <div style="font-family:Arial,sans-serif;max-width:480px;margin:0 auto;color:#1E293B;">
      <h2 style="color:#2563EB;">You're all set!</h2>
      <p>Hi ${patientName},</p>
      <p>Your appointment is confirmed:</p>
      <p style="background:#F8FAFC;border:1px solid #E2E8F0;border-radius:8px;padding:16px;">
        <strong>${practitionerName}</strong><br>
        ${locationName ? locationName + '<br>' : ''}
        ${dateLabel} at ${time}
      </p>
      <p>See you then.</p>
      <p style="color:#64748B;font-size:13px;">If you didn't make this booking, please ignore this email.</p>
    </div>
  `;

  try {
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + process.env.RESEND_API_KEY,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from: 'Atlas <onboarding@resend.dev>',
        to: [to],
        subject: 'Your appointment is confirmed',
        html
      })
    });

    const data = await response.json();

    if (!response.ok) {
      return res.status(500).json({ error: data.message || 'Resend rejected the request.', resendResponse: data });
    }

    return res.status(200).json({ success: true, id: data.id });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
}
