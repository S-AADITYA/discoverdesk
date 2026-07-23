// Vercel serverless function: POST /api/notify
// Sends real email. Two backends, picked by env:
//   1) Gmail as GMAIL_SENDER (e.g. smb@myhaulstore.com) via the Google service
//      account with DOMAIN-WIDE DELEGATION. Set GMAIL_SENDER + reuse
//      GOOGLE_SA_EMAIL / GOOGLE_SA_KEY. The Workspace admin must authorize the
//      SA's client id for scope https://www.googleapis.com/auth/gmail.send and
//      the sender must be a real mailbox in that Workspace.
//   2) Fallback: Resend (RESEND_API_KEY + EMAIL_FROM).
// Body: { to: string|string[], cc?: string|string[], subject, text }
const { google } = require('googleapis');

function b64url(s) {
  return Buffer.from(s).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });

  let body;
  try { body = typeof req.body === 'object' && req.body ? req.body : JSON.parse(req.body || '{}'); }
  catch { body = {}; }
  const { to, cc, subject, text } = body;
  const toArr = Array.isArray(to) ? to.filter(Boolean) : (to ? [to] : []);
  const ccArr = Array.isArray(cc) ? cc.filter(Boolean) : (cc ? [cc] : []);
  if (!toArr.length && !ccArr.length) return res.status(400).json({ error: 'missing recipient' });

  const GMAIL_SENDER = process.env.GMAIL_SENDER;
  const SA_EMAIL = process.env.GOOGLE_SA_EMAIL;
  const SA_KEY = (process.env.GOOGLE_SA_KEY || '').replace(/\\n/g, '\n');

  // ---- 1) Gmail (send AS GMAIL_SENDER via service-account impersonation) ----
  if (GMAIL_SENDER && SA_EMAIL && SA_KEY) {
    try {
      const auth = new google.auth.JWT(SA_EMAIL, null, SA_KEY,
        ['https://www.googleapis.com/auth/gmail.send'], GMAIL_SENDER);
      const gmail = google.gmail({ version: 'v1', auth });
      const headers = [`From: ${GMAIL_SENDER}`, `To: ${(toArr.length ? toArr : ccArr).join(', ')}`];
      if (ccArr.length) headers.push(`Cc: ${ccArr.join(', ')}`);
      headers.push('MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8',
        `Subject: ${(subject || 'DiscoverDesk').replace(/[\r\n]/g, ' ')}`);
      const raw = b64url(headers.join('\r\n') + '\r\n\r\n' + (text || ''));
      const r = await gmail.users.messages.send({ userId: 'me', requestBody: { raw } });
      return res.status(200).json({ ok: true, via: 'gmail', sender: GMAIL_SENDER, id: r.data.id });
    } catch (e) {
      // Surface the reason (usually: delegation not authorized) but don't 500.
      return res.status(200).json({ ok: false, via: 'gmail', error: String(e && e.message || e) });
    }
  }

  // ---- 2) Resend fallback ----
  const key = process.env.RESEND_API_KEY;
  const from = process.env.EMAIL_FROM || 'DiscoverDesk <onboarding@resend.dev>';
  if (!key) return res.status(200).json({ ok: false, skipped: 'no email backend configured (set GMAIL_SENDER or RESEND_API_KEY)' });
  try {
    const payload = { from, to: toArr.length ? toArr : ccArr.slice(0, 1), subject: subject || 'DiscoverDesk', text: text || '' };
    if (ccArr.length) payload.cc = ccArr;
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await r.json();
    return res.status(200).json({ ok: r.ok, via: 'resend', data });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e) });
  }
};
