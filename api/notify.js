// Vercel serverless function: POST /api/notify
// Sends real email via Resend. The secret key lives ONLY here (server-side),
// set as an environment variable in Vercel — never in the browser code.
module.exports = async (req, res) => {
  // CORS (same-origin in production, but harmless)
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

  const key = process.env.RESEND_API_KEY;
  const from = process.env.EMAIL_FROM || 'DiscoverDesk <onboarding@resend.dev>';
  if (!key) return res.status(200).json({ ok: false, skipped: 'RESEND_API_KEY not set' });

  try {
    // Vercel parses JSON bodies automatically; fall back just in case.
    const body = typeof req.body === 'object' && req.body ? req.body : JSON.parse(req.body || '{}');
    const { to, subject, text } = body;
    if (!to) return res.status(400).json({ error: 'missing recipient' });

    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from,
        to: [to],
        subject: subject || 'DiscoverDesk',
        text: text || '',
      }),
    });
    const data = await r.json();
    return res.status(200).json({ ok: r.ok, data });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e) });
  }
};
