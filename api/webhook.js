// Vercel serverless function: POST /api/webhook
// Forwards DiscoverDesk events to any external URL (Slack, Zapier, Make, Teams, custom).
// Runs server-side so it isn't blocked by browser CORS.
module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'POST only' });

  try {
    const body = typeof req.body === 'object' && req.body ? req.body : JSON.parse(req.body || '{}');
    const { url, payload, text } = body;
    if (!url) return res.status(400).json({ ok: false, error: 'missing url' });

    // Slack/Teams expect { text }; Zapier/Make/custom accept the full payload. Send both.
    const out = Object.assign({ text: text || (payload && payload.text) || 'DiscoverDesk event' }, payload || {});
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(out),
    });
    return res.status(200).json({ ok: r.ok, status: r.status });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e) });
  }
};
