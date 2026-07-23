// /api/sheets-sync — sync the multi-tab "Discover Desk - Live sheet" into the ROSTER table.
//   POST { action:"pull" }  → read EVERY tab, parse per-tab, upsert rows into public.roster
//   POST { action:"push", range:"Tab!A1" } → write recently-updated roster rows to ONE range
//   GET  (cron)             → pull only (safe: never writes back to the sheet)
//
// The live sheet is NOT one clean table: it has ~20+ tabs with DIFFERENT column
// schemas (a rich 15-col roster, a 7-col list, etc.), sometimes several stacked
// tables per tab. So this reads each tab, splits it into header-delimited
// segments, maps columns by HEADER NAME (not fixed position), extracts the
// handle from the profile URL, and merges duplicates by handle. Writes to
// `roster` (id/data/contact jsonb) with the app's own field names, matching on
// handle so re-syncing updates a creator in place instead of duplicating.
// Runs with the Supabase SERVICE key (bypasses the anon contact-masking view).
//
// Env (Vercel → Settings → Environment Variables):
//   SUPABASE_URL, SUPABASE_SERVICE_KEY
//   GOOGLE_SA_EMAIL, GOOGLE_SA_KEY   (service account; SHARE THE SHEET with this email, Viewer is enough)
//   SHEET_ID
//   SHEET_RANGE  (optional) — a single "Tab!A1:Z" to sync ONLY that tab; omit/"ALL" to sync every tab
// npm i @supabase/supabase-js googleapis
const { createClient } = require('@supabase/supabase-js');
const { google } = require('googleapis');

function sheetsClient() {
  const auth = new google.auth.JWT(
    process.env.GOOGLE_SA_EMAIL, null,
    (process.env.GOOGLE_SA_KEY || '').replace(/\\n/g, '\n'),
    ['https://www.googleapis.com/auth/spreadsheets']
  );
  return google.sheets({ version: 'v4', auth });
}

// ---------- parsing helpers ----------
const parseCount = v => {
  const s = ('' + (v ?? '')).trim().toLowerCase().replace(/,/g, '');
  if (!s) return 0;
  const m = s.match(/([\d.]+)\s*(k|m|mn|l|lac|lakh|cr|crore)?/);
  if (!m || !m[1]) return 0;
  const n = parseFloat(m[1]); if (!isFinite(n)) return 0;
  const mult = { k: 1e3, m: 1e6, mn: 1e6, l: 1e5, lac: 1e5, lakh: 1e5, cr: 1e7, crore: 1e7 }[m[2] || ''] || 1;
  return Math.round(n * mult);
};
const money = v => { const n = parseFloat(('' + (v ?? '')).replace(/[^\d.]/g, '')); return isFinite(n) ? Math.round(n) : 0; };
const splitList = s => ('' + (s ?? '')).split(/[\/,;]| and | & /i).map(x => x.trim()).filter(Boolean);
const str = v => ('' + (v ?? '')).trim();
const RESERVED = new Set(['reel', 'reels', 'p', 'tv', 'stories', 'story', 'explore', 'accounts', 'about']);

function handleFrom(link, name) {
  const u = str(link).split(/\s/)[0].split('?')[0].replace(/\/+$/, '');
  const afterHost = u.replace(/^https?:\/\//i, '').replace(/^(www|m|mobile)\./i, '');
  const parts = afterHost.split('/').filter(Boolean);
  if (parts.length >= 2) {
    const host = parts[0].toLowerCase();
    if (/instagram|youtube|tiktok|facebook/.test(host)) {
      let seg = parts[1].replace(/^@/, '');
      // YouTube channel-prefix URLs: /c/Name, /user/Name, /channel/UC... → real id is next segment
      if (/youtube/.test(host) && ['c', 'user', 'channel'].includes(seg.toLowerCase()) && parts[2])
        seg = parts[2].replace(/^@/, '');
      if (seg && !RESERVED.has(seg.toLowerCase())) return seg.toLowerCase();
    }
  }
  const n = str(name).toLowerCase().replace(/[^a-z0-9]+/g, '.').replace(/^\.|\.$/g, '');
  return n || '';
}
function platformFrom(link, explicit) {
  const e = str(explicit);
  if (e && !/^\d/.test(e) && e !== ':-:') return e;
  const u = str(link).toLowerCase();
  if (u.includes('youtube') || u.includes('youtu.be')) return 'YouTube';
  if (u.includes('tiktok')) return 'TikTok';
  if (u.includes('facebook')) return 'Facebook';
  return 'Instagram';
}
const looksHeader = r => {
  const low = r.map(c => str(c).toLowerCase());
  // Needs a header-label name column AND a header-label followers/profile column.
  // Deliberately strict: bare "creator" and value-substrings like "instagram"/"url"
  // are NOT used, because data rows carry a "Creator" category or an instagram URL.
  return low.some(c => c === 'name' || c.includes('full name') || c.includes('full_name') || c.includes('creator name') || c.includes('influencer name'))
      && low.some(c => c.includes('profile') || c.includes('follower') || c.includes('subs') || c.includes('channel'));
};
function mapHeader(hdr) {
  const low = hdr.map(c => str(c).toLowerCase());
  const find = (...names) => low.findIndex(c => names.some(n => c.includes(n)));
  return {
    name: find('name', 'creator'), link: find('profile', 'link', 'url', 'channel'),
    followers: find('follower', 'subs'), category: find('categ', 'niche', 'genre'),
    language: find('language', 'lang'), location: find('location', 'city'),
    platform: find('platform'), gender: find('gender'), tier: find('tier'),
    addedBy: find('added by', 'added'), phone: find('number', 'phone', 'mobile', 'whatsapp', 'contact'),
    email: find('email', 'e-mail', 'mail'), reel: find('reel cost', 'reel'),
    videoStory: find('video story', 'separate video'), storeCost: find('commercials for store', 'store visit cost'),
    storeOk: find('available for store'), storyReshare: find('story reshare'), cost: find('cost', 'price', 'charge'),
  };
}
const at = (r, i) => (i >= 0 && i < r.length ? r[i] : '');

// Split one tab's rows into header-delimited segments and emit records.
function recordsFromTab(rows) {
  const out = [];
  const isEmpty = r => !r || r.every(c => !str(c));
  let seg = null;
  for (const r of rows) {
    if (isEmpty(r)) continue;
    if (looksHeader(r)) { seg = { map: mapHeader(r) }; continue; }
    if (!seg) continue; // rows before the first header have no schema
    const m = seg.map;
    const name = str(at(r, m.name)), link = str(at(r, m.link));
    if (!name && !link) continue;
    const handle = handleFrom(link, name);
    if (!handle) continue;
    const platform = platformFrom(link, at(r, m.platform));
    const d = { handle, handles: { [platform.toLowerCase()]: handle }, name: name || handle, platform,
                profileUrl: link || '', source: 'sheet', pricing: {} };
    // ignore numeric category_id columns (FK ids, not real category names)
    const category = /^\d+$/.test(str(at(r, m.category))) ? '' : str(at(r, m.category));
    if (category) d.category = category;
    const niches = splitList(category).map(x => x.toLowerCase()); if (niches.length) d.niches = niches;
    const languages = splitList(at(r, m.language)); if (languages.length) d.languages = languages;
    const city = str(at(r, m.location)); if (city) { d.city = city; d.country = 'India'; }
    const gender = str(at(r, m.gender)); if (gender) d.gender = gender;
    const tier = str(at(r, m.tier)); if (tier) d.tier = tier;
    const addedBy = str(at(r, m.addedBy)); if (addedBy) d.addedByName = addedBy;
    const followers = parseCount(at(r, m.followers)); if (followers) d.followers = followers;
    const reel = money(at(r, m.reel)) || money(at(r, m.cost)); if (reel) { d.reelCost = reel; d.pricing.reel = reel; }
    const vs = money(at(r, m.videoStory)); if (vs) { d.videoStory = vs; d.pricing.story = vs; }
    const sv = money(at(r, m.storeCost)); if (sv) { d.storeVisit = sv; d.pricing.storeVisit = sv; }
    const sr = money(at(r, m.storyReshare)); if (sr) d.pricing.storyReshare = sr;
    d.storeVisitAvailable = /^y|yes|available/.test(str(at(r, m.storeOk)).toLowerCase());
    const contact = {};
    const phone = str(at(r, m.phone)).replace(/\s+/g, ' '); if (phone) contact.phone = phone;
    const email = str(at(r, m.email)); if (email) contact.email = email;
    out.push({ d, contact });
  }
  return out;
}

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();

  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: 'SUPABASE_URL / SUPABASE_SERVICE_KEY not set' });
  if (!process.env.GOOGLE_SA_EMAIL || !process.env.GOOGLE_SA_KEY)
    return res.status(500).json({ ok: false, error: 'GOOGLE_SA_EMAIL / GOOGLE_SA_KEY not set' });
  if (!process.env.SHEET_ID) return res.status(500).json({ ok: false, error: 'SHEET_ID not set' });

  const sb = createClient(url, key);
  const sheets = sheetsClient();
  const SHEET_ID = process.env.SHEET_ID;
  const RANGE = process.env.SHEET_RANGE && process.env.SHEET_RANGE.toUpperCase() !== 'ALL' ? process.env.SHEET_RANGE : null;
  const body = (req.body && typeof req.body === 'object') ? req.body : (() => { try { return JSON.parse(req.body || '{}'); } catch { return {}; } })();
  // GET ?status=1 (or POST {action:'status'}) → fast health check, no sync/DB write.
  const action = (req.method === 'GET')
    ? ((req.query && req.query.status) ? 'status' : 'pull')
    : (body.action || 'pull');

  try {
    let created = 0, updated = 0, tabs = 0;

    if (action === 'status') {
      const meta = await sheets.spreadsheets.get({ spreadsheetId: SHEET_ID, fields: 'properties.title,sheets.properties.title' });
      return res.status(200).json({
        ok: true, linked: true, sheetId: SHEET_ID,
        title: meta.data.properties && meta.data.properties.title || '',
        tabs: (meta.data.sheets || []).length,
        scope: RANGE || 'all tabs',
      });
    }

    if (action === 'pull') {
      // Which tabs? A specific SHEET_RANGE limits to one; otherwise every tab.
      let ranges;
      if (RANGE) ranges = [RANGE];
      else {
        const meta = await sheets.spreadsheets.get({ spreadsheetId: SHEET_ID, fields: 'sheets.properties.title' });
        ranges = (meta.data.sheets || []).map(s => `'${s.properties.title.replace(/'/g, "''")}'`);
      }
      tabs = ranges.length;

      // Parse all tabs → merge by handle (later, richer record wins per field).
      const byHandle = new Map();
      for (const range of ranges) {
        let rows;
        try { rows = (await sheets.spreadsheets.values.get({ spreadsheetId: SHEET_ID, range })).data.values || []; }
        catch { continue; }
        for (const { d, contact } of recordsFromTab(rows)) {
          const prev = byHandle.get(d.handle);
          if (!prev) { byHandle.set(d.handle, { d: { ...d }, contact: { ...contact } }); continue; }
          const pricingWas = prev.d.pricing, handlesWas = prev.d.handles, svaWas = prev.d.storeVisitAvailable;
          prev.d = { ...prev.d, ...Object.fromEntries(Object.entries(d).filter(([, v]) => v !== '' && v != null && !(Array.isArray(v) && !v.length))) };
          prev.d.pricing = { ...pricingWas, ...d.pricing };
          prev.d.handles = { ...handlesWas, ...d.handles };
          prev.d.storeVisitAvailable = svaWas || d.storeVisitAvailable;
          prev.contact = { ...prev.contact, ...contact };
        }
      }
      const unique = [...byHandle.values()];
      for (const u of unique)
        u.d.priceType = (u.d.reelCost || u.d.videoStory || u.d.storeVisit || u.d.pricing.reel) ? 'priced' : 'contact';

      // Match existing roster by handle so we update in place, not duplicate.
      const existing = [];
      for (let from = 0; ; from += 1000) {
        const { data, error } = await sb.from('roster').select('id,data,contact').range(from, from + 999);
        if (error) throw error;
        existing.push(...(data || []));
        if (!data || data.length < 1000) break;
      }
      const byExisting = new Map();
      existing.forEach(row => { const h = str(row.data && row.data.handle).toLowerCase().replace(/^@/, ''); if (h) byExisting.set(h, row); });

      const upserts = unique.map(({ d, contact }) => {
        const prev = byExisting.get(d.handle);
        const id = prev ? prev.id : ('sheet:' + d.platform.toLowerCase() + ':' + d.handle);
        d.id = id;
        // merge: keep whatever the app already has, overlay non-empty sheet fields
        const mergedData = Object.assign({}, prev && prev.data, d,
          { pricing: Object.assign({}, prev && prev.data && prev.data.pricing, d.pricing) });
        const mergedContact = Object.assign({}, prev && prev.contact, contact);
        if (prev) updated++; else created++;
        return { id, data: mergedData, contact: mergedContact };
      });

      for (let i = 0; i < upserts.length; i += 500) {
        const { error } = await sb.from('roster').upsert(upserts.slice(i, i + 500), { onConflict: 'id' });
        if (error) throw error;
      }
      await sb.from('kv').upsert({ key: 'dd:rosterver', value: Date.now() }, { onConflict: 'key' });
      return res.status(200).json({ ok: true, tabs, unique: unique.length, created, updated });
    }

    if (action === 'push') {
      const pushRange = body.range || RANGE; // explicit range required; never guess with multi-tab
      if (!pushRange) return res.status(400).json({ ok: false, error: 'push needs an explicit { range: "Tab!A1" }' });
      const since = new Date(Date.now() - 24 * 3600e3).toISOString();
      const { data } = await sb.from('roster').select('id,data,contact,updated_at').gt('updated_at', since).limit(5000);
      if (data && data.length) {
        const header = ['handle', 'name', 'platform', 'followers', 'category', 'city', 'country', 'reel_cost', 'video_story', 'store_visit', 'email', 'phone'];
        const values = [header, ...data.map(row => {
          const d = row.data || {}, c = row.contact || {};
          return [d.handle || '', d.name || '', d.platform || '', d.followers || 0, d.category || '', d.city || '',
                  d.country || '', d.reelCost || 0, d.videoStory || 0, d.storeVisit || 0, c.email || '', c.phone || ''];
        })];
        await sheets.spreadsheets.values.update({
          spreadsheetId: SHEET_ID, range: pushRange.split('!')[0] + '!A1',
          valueInputOption: 'RAW', requestBody: { values },
        });
      }
      return res.status(200).json({ ok: true, pushed: (data || []).length });
    }

    return res.status(400).json({ ok: false, error: 'unknown action' });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e && e.message || e) });
  }
};
