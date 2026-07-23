// Vercel serverless function: POST /api/youtube
// Looks up a public YouTube channel's stats via the YouTube Data API v3 and,
// optionally, writes them onto the matching roster row.
//
//   POST { handle:"@name" }            → resolve by handle
//   POST { channelId:"UC..." }         → resolve by channel id
//   POST { query:"brand name" }        → best-effort search by name
//   add  { rosterId:"<id>" }           → also upsert stats onto that roster row
//
// Env (Vercel → Settings → Environment Variables):
//   YOUTUBE_API_KEY                              (required)
//   SUPABASE_URL, SUPABASE_SERVICE_KEY           (only needed when rosterId is sent)
const API = 'https://www.googleapis.com/youtube/v3';

async function jget(url) {
  const r = await fetch(url);
  const j = await r.json();
  if (j.error) throw new Error(j.error.message || 'YouTube API error');
  return j;
}

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'POST only' });

  const key = process.env.YOUTUBE_API_KEY;
  if (!key) return res.status(200).json({ ok: false, error: 'YOUTUBE_API_KEY not set' });

  let body = req.body;
  if (typeof body === 'string') { try { body = JSON.parse(body); } catch { body = {}; } }
  let { handle, channelId, query, rosterId } = body || {};

  try {
    // Resolve a channel id if we were only given a handle or a search term.
    if (!channelId && handle) {
      const h = ('' + handle).trim().replace(/^@/, '');
      const j = await jget(`${API}/channels?part=id&forHandle=${encodeURIComponent(h)}&key=${key}`);
      channelId = j.items && j.items[0] && j.items[0].id;
    }
    if (!channelId && query) {
      const j = await jget(`${API}/search?part=snippet&type=channel&maxResults=1&q=${encodeURIComponent(query)}&key=${key}`);
      channelId = j.items && j.items[0] && j.items[0].id && j.items[0].id.channelId;
    }
    if (!channelId) return res.status(200).json({ ok: false, error: 'Channel not found' });

    const j = await jget(`${API}/channels?part=snippet,statistics&id=${encodeURIComponent(channelId)}&key=${key}`);
    const c = j.items && j.items[0];
    if (!c) return res.status(200).json({ ok: false, error: 'Channel not found' });

    const stats = c.statistics || {}, snip = c.snippet || {};
    const out = {
      channelId,
      handle: snip.customUrl || handle || '',
      name: snip.title || '',
      followers: parseInt(stats.subscriberCount || '0', 10) || 0,   // subscribers
      videoCount: parseInt(stats.videoCount || '0', 10) || 0,
      totalViews: parseInt(stats.viewCount || '0', 10) || 0,
      avgViews: (parseInt(stats.videoCount || '0', 10) > 0)
        ? Math.round((parseInt(stats.viewCount || '0', 10)) / parseInt(stats.videoCount, 10)) : 0,
      country: snip.country || '',
      avatar: (snip.thumbnails && snip.thumbnails.default && snip.thumbnails.default.url) || '',
    };

    // Optionally write onto a roster row (service key bypasses the masking view).
    if (rosterId && process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_KEY) {
      const { createClient } = require('@supabase/supabase-js');
      const sb = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_KEY);
      const { data: existing } = await sb.from('roster').select('id,data').eq('id', rosterId).single();
      if (existing) {
        const data = Object.assign({}, existing.data, {
          platform: 'YouTube',
          followers: out.followers || existing.data.followers,
          avgViews: out.avgViews || existing.data.avgViews,
          country: out.country || existing.data.country,
          ytChannelId: channelId,
          ytVideoCount: out.videoCount,
          ytTotalViews: out.totalViews,
          lastSynced: new Date().toISOString(),
        });
        await sb.from('roster').update({ data }).eq('id', rosterId);
        await sb.from('kv').upsert({ key: 'dd:rosterver', value: Date.now() }, { onConflict: 'key' });
      }
    }

    return res.status(200).json({ ok: true, channel: out });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e && e.message || e) });
  }
};
