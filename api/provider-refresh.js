// /api/provider-refresh — refreshes influencer metrics from a data provider and
// APPENDS a history snapshot (old data is kept, never overwritten).
// Runs on a cron every 8 hours (see vercel.json), processing a batch each run so
// it scales to tens of millions of rows over time.
//
// Provider-agnostic: point it at whichever influencer data API you use
// (e.g. Modash, HypeAuditor, Phyllo, IQData — or your "ETA" provider) by setting:
//   PROVIDER_BASE_URL   e.g. https://api.yourprovider.com/v1
//   PROVIDER_API_KEY
// The mapping in `mapProvider()` is where you adapt to that API's response shape.
// Env: SUPABASE_URL, SUPABASE_SERVICE_KEY, PROVIDER_BASE_URL, PROVIDER_API_KEY
// npm i @supabase/supabase-js
const { createClient } = require('@supabase/supabase-js');

const BATCH = 200; // rows per run; raise the cron frequency to cover more

function mapProvider(p) {
  // Adapt these paths to your provider's JSON. Unknown fields are simply skipped.
  return {
    followers:    p.followers ?? p.followers_count ?? p.audience?.count,
    engagement:   p.engagement_rate ?? p.engagement ?? p.er,
    avg_likes:    p.avg_likes ?? p.average_likes,
    avg_comments: p.avg_comments ?? p.average_comments,
    avg_views:    p.avg_views ?? p.average_views,
    bio:          p.biography ?? p.bio,
    avatar_url:   p.profile_picture ?? p.avatar,
    audience:     p.audience_demographics ?? p.audience ?? undefined,
    handles:      p.social_links ?? undefined,
    content:      (p.recent_posts ?? p.last_posts ?? []).slice(0, 10),
  };
}

module.exports = async (req, res) => {
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_KEY;
  const base = process.env.PROVIDER_BASE_URL, pkey = process.env.PROVIDER_API_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: 'Supabase env not set' });
  const sb = createClient(url, key);

  try {
    // pick the most-stale rows (never synced, or older than 8h)
    const cutoff = new Date(Date.now() - 8 * 3600e3).toISOString();
    const { data: due, error } = await sb.from('influencers')
      .select('id, platform, handle, last_synced')
      .or(`last_synced.is.null,last_synced.lt.${cutoff}`)
      .order('last_synced', { ascending: true, nullsFirst: true })
      .limit(BATCH);
    if (error) throw error;
    if (!due || !due.length) return res.status(200).json({ ok: true, refreshed: 0, note: 'nothing due' });

    let refreshed = 0;
    for (const row of due) {
      let mapped = {};
      if (base && pkey) {
        try {
          const r = await fetch(`${base}/profile?platform=${row.platform}&handle=${encodeURIComponent(row.handle)}`,
            { headers: { Authorization: `Bearer ${pkey}` } });
          const j = await r.json();
          mapped = mapProvider(j.data || j || {});
        } catch (_) { /* skip this one, keep going */ }
      }
      const now = new Date().toISOString();
      const upd = { last_synced: now };
      ['followers','engagement','avg_likes','avg_comments','avg_views','bio','avatar_url','audience','handles']
        .forEach(k => { if (mapped[k] != null) upd[k] = mapped[k]; });
      await sb.from('influencers').update(upd).eq('id', row.id);

      // append-only history snapshot (growth tracking)
      await sb.from('influencer_history').insert({
        influencer_id: row.id, captured_at: now,
        followers: mapped.followers ?? null, engagement: mapped.engagement ?? null,
        avg_likes: mapped.avg_likes ?? null, avg_comments: mapped.avg_comments ?? null, avg_views: mapped.avg_views ?? null,
      });

      // refresh last posts
      if (Array.isArray(mapped.content) && mapped.content.length) {
        await sb.from('influencer_content').delete().eq('influencer_id', row.id);
        await sb.from('influencer_content').insert(mapped.content.map(c => ({
          influencer_id: row.id, permalink: c.permalink || c.url, media_type: c.type,
          posted_at: c.timestamp || c.posted_at, likes: c.likes, comments: c.comments, views: c.views, caption: c.caption,
        })));
      }
      refreshed++;
    }
    return res.status(200).json({ ok: true, refreshed });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e && e.message || e) });
  }
};
