// Vercel cron: GET /api/flag-sweep  (scheduled in vercel.json)
// Emails overdue / red-flagged requests to the request's chain people — runs
// server-side so alerts go out even when nobody is logged in. De-dupes via a
// kv marker so each request is emailed once per distinct flag state.
// Env: SUPABASE_URL, SUPABASE_SERVICE_KEY
const { createClient } = require('@supabase/supabase-js');

const CHAIN_SUBJECT = d => `${d.brandName || 'Brand'} > ${d.campaignName || 'Campaign'} -- Discovery ( Internal )`;
const nfmt = n => { n = +n || 0; return n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(0) + 'K' : String(n); };

const roundStatus = rd => rd.status || (rd.decision ? 'decided' : 'submitted');
const openRound = d => (d.rounds || []).some(rd => roundStatus(rd) === 'open');
const discRunning = d => !!(d.discoveryStartedAt && !d.discoveryEndedAt);
// Overdue ONLY while discovery is actively working an OPEN round past its
// deadline. Submitted / between-rounds / delivered are never overdue — the
// deadline is met on submit and a new one comes with the next round.
const isOverdue = (d, now) => !!(d.deadline && d.deadline < now && d.status !== 'approved' && d.status !== 'draft' && discRunning(d) && openRound(d));

function flagsOf(d, now) {
  const f = [];
  if (!d || d.status === 'approved' || d.status === 'draft') return f;
  if (isOverdue(d, now)) f.push('Overdue');
  const rej = (d.rounds || []).filter(x => x.decision === 'rejected').length;
  if (rej >= 2) f.push(rej + ' rejections');
  if (d.status === 'under_review' && d.submittedAt && (now - d.submittedAt) > 3 * 864e5) f.push('Review stalled');
  if (!d.assigneeId && !d.assignedToId && d.status !== 'draft') f.push('Unassigned');
  if (d.priority === 'high' && discRunning(d) && openRound(d) && d.deadline && d.deadline - now < 2 * 864e5 && d.deadline - now > -1) f.push('High-pri due soon');
  return f;
}

module.exports = async (req, res) => {
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_KEY;
  if (!url || !key) return res.status(500).json({ ok: false, error: 'SUPABASE_URL / SUPABASE_SERVICE_KEY not set' });
  const sb = createClient(url, key);
  const now = Date.now();
  try {
    const [{ data: reqRows }, { data: profRows }, { data: kvRow }] = await Promise.all([
      sb.from('requests').select('id,data'),
      sb.from('profiles').select('id,email,status,role_key,role,locked'),
      sb.from('kv').select('value').eq('key', 'dd:flagsweep').maybeSingle(),
    ]);
    const prof = {}; (profRows || []).forEach(p => { prof[p.id] = p; });
    const primaryAdmins = (profRows || []).filter(p => p.status === 'active' && p.email && (p.locked === true || p.role === 'admin' || p.role_key === 'admin'));
    const marker = (kvRow && kvRow.value) || {};
    let sent = 0, flaggedCount = 0;

    for (const row of (reqRows || [])) {
      const d = row.data || {}; if (d.deletedAt) continue;
      const f = flagsOf(d, now); const sig = f.join('|');
      if (!f.length) { if (marker[row.id]) delete marker[row.id]; continue; }
      flaggedCount++;
      if (marker[row.id] === sig) continue;            // already emailed this exact flag state
      // TO = requester + routed manager + assigned discovery; CC = permanent admin
      const toIds = [d.requesterId, d.routedToManagerId, d.assigneeId, d.assignedToId].filter(Boolean);
      const to = [...new Set(toIds.map(id => prof[id]).filter(p => p && p.email && p.status === 'active').map(p => p.email))];
      const cc = [...new Set(primaryAdmins.map(p => p.email))].filter(e => !to.includes(e));
      marker[row.id] = sig;
      if (!to.length && !cc.length) continue;
      const subject = CHAIN_SUBJECT(d);
      const disc = prof[d.assigneeId || d.assignedToId]; const req = prof[d.requesterId];
      const text = `⚠ Request flagged\n\nBrand: ${d.brandName || '—'}\nCampaign: ${d.campaignName || '—'}\nFlags: ${f.join(', ')}\nDeadline: ${d.deadline ? new Date(d.deadline).toLocaleString('en-GB') : 'TBD'}\nRaised by: ${(req && req.email) || '—'}\nDiscovery: ${(disc && disc.email) || 'nobody yet'}\n\nThis request has tripped a red flag — please action it.`;
      try {
        await fetch('https://discoverdesk.vercel.app/api/notify', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ to, cc, subject, text }),
        });
        sent++;
      } catch (e) { /* leave marker set to avoid retry storms; next state change re-sends */ }
    }
    await sb.from('kv').upsert({ key: 'dd:flagsweep', value: marker, updated_at: new Date().toISOString() });
    return res.status(200).json({ ok: true, checked: (reqRows || []).length, flagged: flaggedCount, emailed: sent });
  } catch (e) {
    return res.status(200).json({ ok: false, error: String(e && e.message || e) });
  }
};
