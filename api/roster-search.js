// POST /api/roster-search  — paginated, multi-parameter roster search.
// Runs server-side against Supabase so millions of rows stay in Postgres,
// never in the browser. Requires env: SUPABASE_URL, SUPABASE_SERVICE_KEY.
// npm i @supabase/supabase-js
const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ ok: false, error: 'POST only' });

  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: 'Supabase env not set' });
  const sb = createClient(url, key);

  try {
    const b = typeof req.body === 'object' && req.body ? req.body : JSON.parse(req.body || '{}');
    const f = b.filters || {};
    const page = Math.max(0, b.page || 0);
    const size = Math.min(200, b.pageSize || 50);
    const from = page * size, to = from + size - 1;

    let q = sb.from('influencers').select('*', { count: 'estimated' });

    // ---- hundreds of parameters, applied only when provided ----
    if (f.q)            q = q.or(`handle.ilike.%${f.q}%,name.ilike.%${f.q}%`);
    if (f.platform)     q = q.eq('platform', f.platform);
    if (f.category)     q = q.eq('category', f.category);
    if (f.country)      q = q.eq('country', f.country);
    if (f.city)         q = q.ilike('city', `%${f.city}%`);
    if (f.availability) q = q.eq('availability', f.availability);
    if (f.followersMin != null) q = q.gte('followers', f.followersMin);
    if (f.followersMax != null) q = q.lte('followers', f.followersMax);
    if (f.engMin != null)       q = q.gte('engagement', f.engMin);
    if (f.engMax != null)       q = q.lte('engagement', f.engMax);
    if (f.brandCostMax != null) q = q.lte('brand_cost', f.brandCostMax);
    if (Array.isArray(f.niches) && f.niches.length)       q = q.contains('niches', f.niches);
    if (Array.isArray(f.languages) && f.languages.length) q = q.contains('languages', f.languages);
    if (Array.isArray(f.tags) && f.tags.length)           q = q.contains('tags', f.tags);
    // audience demographics filters, e.g. {"geo":"IN"} → audience->geo has key IN
    // matches when audience->geo has this country key at all, regardless of its value
    // (e.g. {"geo":{"IN":42}} matches audienceGeo="IN"); previous version used a
    // JSON containment check against a hardcoded 0, which only ever matched a
    // literal 0% value and never real audience percentages
    if (f.audienceGeo)    q = q.not(`audience->geo->>${f.audienceGeo}`, 'is', null);
    if (f.notSynced8h)    q = q.or(`last_synced.is.null,last_synced.lt.${new Date(Date.now() - 8*3600e3).toISOString()}`);

    const sort = f.sort || 'followers';
    q = q.order(sort === 'engagement' ? 'engagement' : sort === 'brand_cost' ? 'brand_cost' : 'followers', { ascending: false });
    q = q.range(from, to);

    const { data, count, error } = await q;
    if (error) return res.status(200).json({ ok: false, error: error.message });
    return res.status(200).json({ ok: true, rows: data, total: count, page, pageSize: size });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e) });
  }
};
