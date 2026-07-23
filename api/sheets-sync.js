// /api/sheets-sync — two-way sync between a Google Sheet and the ROSTER table.
//   POST { action:"pull" }  → read the sheet, upsert rows into public.roster
//   POST { action:"push" }  → write recently-updated roster rows back to the sheet
//   GET  (cron)             → runs a pull, then a push
//
// The Google Sheet is your team's data-entry surface; the app's Roster mirrors
// it. This writes to `roster` (the table the app actually shows) using the app's
// own field names, and matches on handle so re-syncing updates a creator in
// place instead of creating a duplicate. Runs with the Supabase SERVICE key, so
// it writes the base table directly — the contact-masking view only applies to
// the browser (anon) client.
//
// Env required (Vercel → Settings → Environment Variables):
//   SUPABASE_URL, SUPABASE_SERVICE_KEY
//   GOOGLE_SA_EMAIL, GOOGLE_SA_KEY   (service account; SHARE THE SHEET with this email)
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

// Whole-word match for short header tokens (<=3 chars) so "er"/"eng" don't match
// inside "Followers"; substring for longer tokens (e.g. "categor" → "Category").
const col = (headers, row, names) => {
  const i = headers.findIndex(h => {
    const hl = (h || '').toString().toLowerCase();
    return names.some(n => n.length <= 3 ? new RegExp(`\\b${n}\\b`).test(hl) : hl.includes(n));
  });
  return i >= 0 ? (row[i] ?? '') : '';
};

// "12.3k" → 12300, "1.2M" → 1200000, "3.5 lakh" → 350000, "45,678" → 45678.
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
const num = v => { const n = parseFloat(('' + (v ?? '')).replace(/[^\d.]/g, '')); return isFinite(n) ? n : 0; };
const str = v => ('' + (v ?? '')).trim();

module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'POST, GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();

  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: 'SUPABASE_URL / SUPABASE_SERVICE_KEY not set' });
  if (!process.env.GOOGLE_SA_EMAIL || !process.env.GOOGLE_SA_KEY)
    return res.status(500).json({ ok: false, error: 'GOOGLE_SA_EMAIL / GOOGLE_SA_KEY not set' });
  if (!process.env.SHEET_ID)
    return res.status(500).json({ ok: false, error: 'SHEET_ID not set' });

  const sb = createClient(url, key);
  const sheets = sheetsClient();
  const SHEET_ID = process.env.SHEET_ID, RANGE = process.env.SHEET_RANGE || 'Roster!A1:Z';
  const action = (req.method === 'GET') ? 'both' : ((req.body && req.body.action) || 'pull');

  try {
    let pulled = 0, pushed = 0, created = 0, updated = 0;

    if (action === 'pull' || action === 'both') {
      const r = await sheets.spreadsheets.values.get({ spreadsheetId: SHEET_ID, range: RANGE });
      const rows = r.data.values || [];
      const headers = rows[0] || [];

      // Existing roster, so we can match on handle and update in place rather
      // than duplicate. 157 rows today; paged so it still holds if it grows.
      const existing = [];
      for (let from = 0; ; from += 1000) {
        const { data, error } = await sb.from('roster').select('id,data,contact').range(from, from + 999);
        if (error) throw error;
        existing.push(...(data || []));
        if (!data || data.length < 1000) break;
      }
      const byHandle = new Map();
      existing.forEach(row => {
        const h = norm(row.data && row.data.handle);
        if (h) byHandle.set(h, row);
      });

      const upserts = [];
      for (const row of rows.slice(1)) {
        const handle = norm(col(headers, row, ['handle', 'username', 'user', 'insta', 'profile']) || col(headers, row, ['name']));
        if (!handle) continue;
        const platform = (str(col(headers, row, ['platform'])) || 'Instagram');

        // Only non-empty sheet cells are written, so a blank column never wipes
        // a value a team member entered in the app.
        // Skip empty AND zero: a blank sheet cell parses to 0, and we must not
        // let that overwrite a real follower count / cost already in the app.
        const sheetData = {};
        const set = (k, v) => { if (v !== '' && v != null && v !== 0) sheetData[k] = v; };
        set('handle', handle);
        set('platform', platform);
        set('name', str(col(headers, row, ['full name', 'display', 'name'])));
        set('followers', parseCount(col(headers, row, ['follow', 'audience', 'subs'])));
        set('eng', num(col(headers, row, ['engage', 'eng', 'er'])));
        set('category', str(col(headers, row, ['categor', 'niche', 'genre'])));
        set('city', str(col(headers, row, ['city', 'location'])));
        set('country', str(col(headers, row, ['country'])));
        set('brandCost', parseCount(col(headers, row, ['brand cost', 'client', 'sell', 'quote'])));
        set('internalCost', parseCount(col(headers, row, ['internal', 'creator cost', 'payout', 'buy'])));
        set('profileUrl', str(col(headers, row, ['profile url', 'link', 'url'])));

        const email = str(col(headers, row, ['email', 'e-mail', 'mail']));
        const phone = str(col(headers, row, ['phone', 'mobile', 'contact', 'whatsapp']));

        const prev = byHandle.get(handle);
        const id = prev ? prev.id : ('sheet:' + platform.toLowerCase() + ':' + handle);
        const mergedData = Object.assign({}, prev && prev.data, sheetData, { source: 'sheet' });
        const mergedContact = Object.assign({}, prev && prev.contact,
          email ? { email } : null, phone ? { phone } : null);

        upserts.push({ id, data: mergedData, contact: mergedContact });
        if (prev) updated++; else created++;
      }

      for (let i = 0; i < upserts.length; i += 500) {
        const chunk = upserts.slice(i, i + 500);
        const { error } = await sb.from('roster').upsert(chunk, { onConflict: 'id' });
        if (error) throw error;
        pulled += chunk.length;
      }
      // Bump a version key so other open browsers reload (roster is deliberately
      // NOT in the realtime publication — its payloads would bypass masking).
      await sb.from('kv').upsert({ key: 'dd:rosterver', value: Date.now() }, { onConflict: 'key' });
    }

    if (action === 'push' || action === 'both') {
      const since = new Date(Date.now() - 24 * 3600e3).toISOString();
      const { data } = await sb.from('roster').select('id,data,contact,updated_at').gt('updated_at', since).limit(5000);
      if (data && data.length) {
        const header = ['handle', 'name', 'platform', 'followers', 'engagement', 'category', 'city', 'country', 'brand_cost', 'internal_cost', 'email', 'phone'];
        const values = [header, ...data.map(row => {
          const d = row.data || {}, c = row.contact || {};
          return [d.handle || '', d.name || '', d.platform || '', d.followers || 0, d.eng || 0,
                  d.category || '', d.city || '', d.country || '', d.brandCost || 0, d.internalCost || 0,
                  c.email || '', c.phone || ''];
        })];
        await sheets.spreadsheets.values.update({
          spreadsheetId: SHEET_ID, range: RANGE.split('!')[0] + '!A1',
          valueInputOption: 'RAW', requestBody: { values },
        });
        pushed = data.length;
      }
    }

    return res.status(200).json({ ok: true, pulled, pushed, created, updated });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e && e.message || e) });
  }
};
