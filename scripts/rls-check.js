#!/usr/bin/env node
/*
 * DiscoverDesk — RLS verification (Section E)
 *
 * The sprint asked for scripts/rls-check.ts. This repo has no TypeScript and
 * no build step (it is a single index.html plus Vercel functions), so this is
 * plain Node with no dependencies beyond @supabase/supabase-js, which is
 * already in package.json.
 *
 * It signs in as one real user per role and asserts what each can actually
 * SELECT through the API — i.e. it tests the policies, not the UI.
 *
 * USAGE
 *   1. Create one test user per role in Supabase Auth, set their role_key and
 *      team_uid in profiles, then put their credentials in a JSON file:
 *
 *      // rls-users.json  (git-ignored — never commit real credentials)
 *      {
 *        "admin":              {"email":"...","password":"..."},
 *        "sales_manager":      {"email":"...","password":"..."},
 *        "sales_employee":     {"email":"...","password":"..."},
 *        "kam_manager":        {"email":"...","password":"..."},
 *        "kam_employee":       {"email":"...","password":"..."},
 *        "discovery_manager":  {"email":"...","password":"..."},
 *        "discovery_employee": {"email":"...","password":"..."}
 *      }
 *
 *   2. SUPABASE_URL=... SUPABASE_ANON_KEY=... node scripts/rls-check.js
 *
 * Use the ANON key. Never the service_role key — it bypasses RLS entirely and
 * would make every check pass for the wrong reason.
 */

const fs = require('fs');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');

const URL = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_ANON_KEY;

if (!URL || !ANON) {
  console.error('Set SUPABASE_URL and SUPABASE_ANON_KEY (anon, not service_role).');
  process.exit(1);
}
if (/service_role/i.test(ANON) || (ANON.split('.')[1] &&
    Buffer.from(ANON.split('.')[1], 'base64').toString().includes('service_role'))) {
  console.error('That looks like the service_role key. It bypasses RLS — use the anon key.');
  process.exit(1);
}

const usersFile = path.join(__dirname, 'rls-users.json');
if (!fs.existsSync(usersFile)) {
  console.error('Missing scripts/rls-users.json — see the header of this file.');
  process.exit(1);
}
const USERS = JSON.parse(fs.readFileSync(usersFile, 'utf8'));

// What each role is expected to be able to see. `null` = no expectation on
// count, we only record it. Written as predicates so the matrix stays legible.
const EXPECT = {
  admin:              { people: 'all',        requests: 'all',      enquiries: 'all' },
  sales_manager:      { people: 'own-team',   requests: 'own-team', enquiries: 'own-team' },
  sales_employee:     { people: 'own-team',   requests: 'own',      enquiries: 'own' },
  kam_manager:        { people: 'own-team',   requests: 'own-team', enquiries: 'own-team' },
  kam_employee:       { people: 'own-team',   requests: 'own',      enquiries: 'own' },
  discovery_manager:  { people: 'own-dept',   requests: 'all',      enquiries: 'converted' },
  discovery_employee: { people: 'own-team',   requests: 'assigned', enquiries: 'none' },
};

async function countAs(sb, table) {
  const { count, error } = await sb.from(table).select('*', { count: 'exact', head: true });
  if (error) return { error: error.message };
  return { count: count || 0 };
}

(async () => {
  const rows = [];
  let failures = 0;

  // Baseline: totals as seen by the admin account.
  let totals = {};
  {
    const sb = createClient(URL, ANON);
    const cred = USERS.admin;
    if (!cred) { console.error('rls-users.json needs at least an "admin" entry.'); process.exit(1); }
    const { error } = await sb.auth.signInWithPassword(cred);
    if (error) { console.error('admin sign-in failed:', error.message); process.exit(1); }
    for (const t of ['profiles', 'requests', 'enquiries']) totals[t] = (await countAs(sb, t)).count;
    await sb.auth.signOut();
  }

  for (const [role, cred] of Object.entries(USERS)) {
    const sb = createClient(URL, ANON);
    const { error: authErr } = await sb.auth.signInWithPassword(cred);
    if (authErr) {
      rows.push({ role, people: 'SIGN-IN FAILED', requests: '-', enquiries: '-', verdict: 'ERROR' });
      failures++;
      continue;
    }

    const people = await countAs(sb, 'profiles');
    const reqs   = await countAs(sb, 'requests');
    const enqs   = await countAs(sb, 'enquiries');

    // The one hard, universal assertion: only admin may see everything.
    let verdict = 'ok';
    const exp = EXPECT[role];
    if (exp) {
      if (exp.requests !== 'all' && reqs.count === totals.requests && totals.requests > 0) {
        verdict = 'FAIL: sees ALL requests';
        failures++;
      }
      if (exp.enquiries === 'none' && enqs.count > 0) {
        verdict = 'FAIL: sees enquiries it should not';
        failures++;
      }
      if (exp.people !== 'all' && people.count === totals.profiles && totals.profiles > 1) {
        verdict = 'FAIL: sees ALL people';
        failures++;
      }
    }

    rows.push({
      role,
      people: people.error ? 'ERR' : `${people.count}/${totals.profiles}`,
      requests: reqs.error ? 'ERR' : `${reqs.count}/${totals.requests}`,
      enquiries: enqs.error ? 'ERR' : `${enqs.count}/${totals.enquiries}`,
      verdict,
    });

    await sb.auth.signOut();
  }

  console.log('\nRLS visibility (visible / total as admin)\n');
  console.table(rows);

  if (failures) {
    console.error(`\n${failures} check(s) FAILED — a non-admin role can see more than the matrix allows.`);
    process.exit(1);
  }
  console.log('\nAll roles are correctly scoped.');
})();
