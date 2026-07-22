// /api/sheets-sync — two-way sync between a Google Sheet and the influencers table.
//   POST { action:"pull" }  → read the sheet, upsert rows into Supabase
//   POST { action:"push" }  → write recently-updated influencers back to the sheet
//   GET  (cron)             → runs a pull, then a push
//
// Google Sheets stays your team's data-entry surface; the app mirrors it.
// Env required:
//   SUPABASE_URL, SUPABASE_SERVICE_KEY
//   GOOGLE_SA_EMAIL, GOOGLE_SA_KEY   (service account; share the sheet with this email)
//   SHEET_ID, SHEET_RANGE            (e.g. "Roster!A1:Z")
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
const norm = h => (h || '').toString().trim().toLowerCase().replace(/^@/, '');
const col = (headers, row, names) => {
  // Short tokens (<=3 chars, e.g. "er", "eng") used to match as a plain substring,
  // which meant "er" matched inside "Followers" and engagement got silently read
  // from the followers column instead. Short tokens now require a whole-word match;
  // longer tokens keep substring matching (e.g. "categor" -> "Category").
  const i = headers.findIndex(h => {
    const hl = h.toLowerCase();
    return names.some(n => n.length <= 3 ? new RegExp(`\\b${n}\\b`).test(hl) : hl.includes(n));
  });
  return i >= 0 ? row[i] : '';
};
// Parses sheet numbers like "12.3k", "1.2M", "3.5 lakh", "45,678" into a real
// integer. A plain digit-strip (the old approach) mangles these — "12.3k"
// became 123 instead of 12300, and "1.2M" became 12 instead of 1200000.
const parseCount = v => {
  const s = ('' + (v ?? '')).trim().toLowerCase().replace(/,/g, '');
  if (!s) return 0;
  const m = s.match(/^([\d.]+)\s*(k|m|mn|l|lac|lakh|cr|crore)?/);
  if (!m || !m[1]) return 0;
  const n = parseFloat(m[1]);
  if (!isFinite(n)) return 0;
  const mult = { k: 1e3, m: 1e6, mn: 1e6, l: 1e5, lac: 1e5, lakh: 1e5, cr: 1e7, crore: 1e7 }[m[2] || ''] || 1;
  return Math.round(n * mult);
};

module.exports = async (req, res) => {
  // CORS: needed because the browser calls this directly (Settings > Sync now),
  // and the frontend may be hosted on a different origin than this function
  // (e.g. static site on Netlify, API on Vercel).
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();

  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: 'Supabase env not set' });
  const sb = createClient(url, key);
  const sheets = sheetsClient();
  const SHEET_ID = process.env.SHEET_ID, RANGE = process.env.SHEET_RANGE || 'Roster!A1:Z';
  console.log("===== SHEETS CONFIG =====");
  console.log("SHEET_ID:", SHEET_ID);
  console.log("RANGE:", RANGE);
  console.log("=========================");
  const action = (req.method === 'GET') ? 'both' : ((req.body && req.body.action) || 'pull');

  try {
    let pulled = 0, pushed = 0;

    if (action === 'pull' || action === 'both') {
      const r = await sheets.spreadsheets.values.get({ spreadsheetId: SHEET_ID, range: RANGE });
      const rows = r.data.values || [];
      const headers = rows[0] || [];
      const recs = rows.slice(1).map(row => {
        const handle = norm(col(headers, row, ['handle', 'username', 'user', 'insta', 'profile']) || col(headers, row, ['name']));
        if (!handle) return null;
        return {
          platform: (col(headers, row, ['platform']) || 'instagram').toLowerCase(),
          handle,
          name: col(headers, row, ['full name', 'display', 'name']),
          followers: parseCount(col(headers, row, ['follow', 'audience', 'subs'])),
          engagement: parseFloat(col(headers, row, ['engage', 'eng', 'er'])) || 0,
          category: col(headers, row, ['categor', 'niche', 'genre']),
          city: col(headers, row, ['city', 'location']),
          country: col(headers, row, ['country']),
          brand_cost: parseCount(col(headers, row, ['brand cost', 'client', 'sell', 'quote'])),
          internal_cost: parseCount(col(headers, row, ['internal', 'creator cost', 'payout', 'buy'])),
          source: 'sheet', last_synced: new Date().toISOString(),
        };
      }).filter(Boolean);
      // upsert in chunks (handles large sheets)
      for (let i = 0; i < recs.length; i += 500) {
        const chunk = recs.slice(i, i + 500);
        const { error } = await sb.from('influencers').upsert(chunk, { onConflict: 'platform,handle' });
        if (error) throw error;
        pulled += chunk.length;
      }
    }

    if (action === 'push' || action === 'both') {
      // push rows updated in the app in the last day back to the sheet
      const since = new Date(Date.now() - 24 * 3600e3).toISOString();
      const { data } = await sb.from('influencers').select('*').gt('updated_at', since).limit(5000);
      if (data && data.length) {
        const header = ['handle', 'name', 'platform', 'followers', 'engagement', 'category', 'city', 'country', 'brand_cost', 'internal_cost', 'last_synced'];
        const values = [header, ...data.map(d => header.map(h => d[h] ?? ''))];
        await sheets.spreadsheets.values.update({
          spreadsheetId: SHEET_ID, range: RANGE.split('!')[0] + '!A1',
          valueInputOption: 'RAW', requestBody: { values },
        });
        pushed = data.length;
      }
    }

    return res.status(200).json({ ok: true, pulled, pushed });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e && e.message || e) });
  }
};
