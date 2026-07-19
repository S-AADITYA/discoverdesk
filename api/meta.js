// Vercel serverless function: POST /api/meta
// Looks up public Instagram business/creator profiles via the Meta Graph API
// (Instagram Business Discovery). The access token is sent from the app's
// Integrations settings and used only here, server-side.
module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'POST only' });

  try {
    const body = typeof req.body === 'object' && req.body ? req.body : JSON.parse(req.body || '{}');
    const { token, igId, username, media } = body;
    if (!token || !igId || !username) return res.status(400).json({ ok: false, error: 'token, igId and username required' });

    const mediaFields = media ? ',media.limit(10){caption,media_type,media_url,permalink,thumbnail_url,timestamp,like_count,comments_count}' : '';
    const fields = `business_discovery.username(${username}){followers_count,media_count,name,username,profile_picture_url${mediaFields}}`;
    const url = `https://graph.facebook.com/v19.0/${encodeURIComponent(igId)}?fields=${encodeURIComponent(fields)}&access_token=${encodeURIComponent(token)}`;

    const r = await fetch(url);
    const j = await r.json();
    if (j.error) return res.status(200).json({ ok: false, error: j.error.message || 'Meta API error' });

    const bd = j.business_discovery || null;
    return res.status(200).json({ ok: !!bd, data: bd });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e) });
  }
};
