// api/ai-search.js — turns a plain-English discovery query into structured filters.
// This is the REAL AI path the app calls when settings.ai.enabled is on.
// It runs on Vercel (Node), NOT on Hostinger shared hosting.
//
// Set ANTHROPIC_API_KEY in your Vercel project env. Without it, this returns
// {ok:false} and the app cleanly falls back to local keyword parsing.

module.exports = async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'POST only' });

  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) return res.status(200).json({ ok: false, error: 'AI not configured' });

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = {}; } }
  const query = (body && body.query || '').toString().slice(0, 500);
  if (!query) return res.status(400).json({ ok: false, error: 'query required' });

  // The model returns ONLY a JSON object of filters the app understands.
  const system = `You convert an influencer-discovery request into a JSON filter object.
Return ONLY valid JSON, no prose, no markdown. Allowed keys (omit any you can't infer):
followersMin (number), followersMax (number), budgetMax (number, INR),
city (lowercase string), niche (lowercase string), platform ("Instagram"|"YouTube"|"TikTok"),
gender ("Female"|"Male"), priceType ("priced"|"barter"), minAuth (0-100), tier ("nano"|"micro"|"mega").
Convert lakh=100000, crore=10000000, k=1000, m=1000000.`;

  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': key,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-sonnet-4-6',
        max_tokens: 300,
        system,
        messages: [{ role: 'user', content: query }],
      }),
    });
    const data = await r.json();
    const text = (data.content || []).map(b => b.text || '').join('').trim();
    const clean = text.replace(/```json|```/g, '').trim();
    let filters = {};
    try { filters = JSON.parse(clean); } catch { return res.status(200).json({ ok: false, error: 'parse failed', raw: text }); }
    return res.status(200).json({ ok: true, filters });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e && e.message || e) });
  }
}
