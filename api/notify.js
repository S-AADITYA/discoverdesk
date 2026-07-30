// Vercel serverless function: POST /api/notify
// Sends real email (branded HTML + plain-text fallback). Two backends, by env:
//   1) Gmail as GMAIL_SENDER via the Google service account with DOMAIN-WIDE
//      DELEGATION (GMAIL_SENDER + GOOGLE_SA_EMAIL + GOOGLE_SA_KEY, scope
//      https://www.googleapis.com/auth/gmail.send).
//   2) Fallback: Resend (RESEND_API_KEY + EMAIL_FROM).
// Body: { to, cc?, subject, text }  — the plain text is auto-wrapped in HTML.
const { google } = require('googleapis');

function b64url(s) {
  return Buffer.from(s).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}
function linkify(s) {
  return esc(s).replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" style="color:#5847eb;text-decoration:none">$1</a>');
}
// RFC 2047 encoded-word so emoji / ₹ / non-ASCII subjects render correctly.
function encSubject(s) {
  s = String(s || 'DiscoverDesk').replace(/[\r\n]/g, ' ');
  return '=?UTF-8?B?' + Buffer.from(s, 'utf8').toString('base64') + '?=';
}
// Clean, structured branded HTML. The first line of `text` becomes the event
// heading; "Label: value" lines render as a details table; the rest as body.
function htmlWrap(text, subject) {
  const thread = String(subject || '').replace(/^\[[^\]]*\]\s*/, '');
  const lines = String(text || '').replace(/\r/g, '').split('\n');
  let i = 0; while (i < lines.length && lines[i].trim() === '') i++;
  const eventHead = i < lines.length ? lines[i] : (thread || 'Update');
  const rest = lines.slice(i + 1);
  const rows = [], paras = [];
  rest.forEach(l => {
    const m = l.match(/^([A-Za-z][A-Za-z0-9 /&()·.\-]{0,40}):\s+(.+)$/);
    if (m) rows.push([m[1], m[2]]); else if (l.trim() !== '') paras.push(l);
  });
  const detailHtml = rows.length ? `<table role="presentation" cellpadding="0" cellspacing="0" style="width:100%;border-collapse:collapse;margin:4px 0 2px;background:#fafafc;border:1px solid #eeeef3;border-radius:12px">${rows.map(([k, v], idx) => `<tr><td style="padding:9px 14px;color:#8a8a99;font-size:12px;white-space:nowrap;vertical-align:top;${idx ? 'border-top:1px solid #f0f0f5' : ''}">${esc(k)}</td><td style="padding:9px 14px;color:#22222e;font-size:13.5px;font-weight:600;${idx ? 'border-top:1px solid #f0f0f5' : ''}">${linkify(v)}</td></tr>`).join('')}</table>` : '';
  const paraHtml = paras.map(p => `<div style="margin:12px 0 0;color:#44444f;font-size:13.5px;line-height:1.65">${linkify(p)}</div>`).join('');
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f4f4f7">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f7;padding:28px 12px">
    <tr><td align="center">
      <table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;background:#ffffff;border:1px solid #e7e7ef;border-radius:16px;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
        <tr><td style="height:4px;line-height:4px;font-size:0;background:#5847eb;background-image:linear-gradient(90deg,#5847eb,#0ea472)">&nbsp;</td></tr>
        <tr><td style="padding:22px 32px 0">
          <div style="font-weight:700;font-size:13px;color:#5847eb;letter-spacing:.3px">◗ DiscoverDesk</div>
          <div style="margin-top:3px;color:#9a9aa6;font-size:12px">${esc(thread)}</div>
        </td></tr>
        <tr><td style="padding:14px 32px 6px">
          <div style="font-size:20px;font-weight:700;color:#18182a;line-height:1.3">${esc(eventHead)}</div>
        </td></tr>
        <tr><td style="padding:8px 32px 4px">${detailHtml}</td></tr>
        ${paraHtml ? `<tr><td style="padding:0 32px 6px">${paraHtml}</td></tr>` : ''}
        <tr><td style="padding:20px 32px 22px 32px"></td></tr>
        <tr><td style="padding:15px 32px;border-top:1px solid #eeeef3;color:#9a9aa6;font-size:12px;line-height:1.5">
          DiscoverDesk · Discovery Ops Platform<br>Automated notification — manage what you receive under Inbox → Email settings.
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>`;
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

  const html = htmlWrap(text, subject);

  const GMAIL_SENDER = process.env.GMAIL_SENDER;
  const SA_EMAIL = process.env.GOOGLE_SA_EMAIL;
  const SA_KEY = (process.env.GOOGLE_SA_KEY || '').replace(/\\n/g, '\n');

  // ---- 1) Gmail (send AS GMAIL_SENDER via service-account impersonation) ----
  if (GMAIL_SENDER && SA_EMAIL && SA_KEY) {
    try {
      const auth = new google.auth.JWT(SA_EMAIL, null, SA_KEY,
        ['https://www.googleapis.com/auth/gmail.send'], GMAIL_SENDER);
      const gmail = google.gmail({ version: 'v1', auth });
      const boundary = 'ddmix_' + Math.random().toString(36).slice(2);
      const headers = [`From: DiscoverDesk <${GMAIL_SENDER}>`, `To: ${(toArr.length ? toArr : ccArr).join(', ')}`];
      if (ccArr.length) headers.push(`Cc: ${ccArr.join(', ')}`);
      headers.push('MIME-Version: 1.0',
        `Content-Type: multipart/alternative; boundary="${boundary}"`,
        `Subject: ${encSubject(subject)}`);
      const mime = [
        `--${boundary}`,
        'Content-Type: text/plain; charset=UTF-8',
        'Content-Transfer-Encoding: 8bit', '',
        (text || ''),
        `--${boundary}`,
        'Content-Type: text/html; charset=UTF-8',
        'Content-Transfer-Encoding: 8bit', '',
        html,
        `--${boundary}--`, '',
      ].join('\r\n');
      const raw = b64url(headers.join('\r\n') + '\r\n\r\n' + mime);
      const r = await gmail.users.messages.send({ userId: 'me', requestBody: { raw } });
      return res.status(200).json({ ok: true, via: 'gmail', sender: GMAIL_SENDER, id: r.data.id });
    } catch (e) {
      return res.status(200).json({ ok: false, via: 'gmail', error: String(e && e.message || e) });
    }
  }

  // ---- 2) Resend fallback ----
  const key = process.env.RESEND_API_KEY;
  const from = process.env.EMAIL_FROM || 'DiscoverDesk <onboarding@resend.dev>';
  if (!key) return res.status(200).json({ ok: false, skipped: 'no email backend configured (set GMAIL_SENDER or RESEND_API_KEY)' });
  try {
    const payload = { from, to: toArr.length ? toArr : ccArr.slice(0, 1), subject: subject || 'DiscoverDesk', text: text || '', html };
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
