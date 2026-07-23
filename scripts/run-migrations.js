#!/usr/bin/env node
/*
 * DiscoverDesk — migration runner
 *
 * Reads SUPABASE_DB_URL from .env.local (git-ignored, so the secret never
 * enters the repo or the chat transcript) and executes supabase-RUN-ALL.sql
 * against the database.
 *
 * The whole file runs inside ONE transaction: if any statement fails,
 * everything rolls back and the database is left exactly as it was. That is
 * the difference between this and pasting into the SQL editor, where a
 * failure halfway leaves you in a partial state.
 *
 *   node scripts/run-migrations.js            # run it
 *   node scripts/run-migrations.js --dry-run  # connect + report only
 */

const fs = require('fs');
const path = require('path');
const { Client } = require('pg');

const ROOT = path.join(__dirname, '..');
const SQL_FILE = path.join(ROOT, 'supabase-RUN-ALL.sql');
const ENV_FILE = path.join(ROOT, '.env.local');
const DRY = process.argv.includes('--dry-run');

function readEnv() {
  if (process.env.SUPABASE_DB_URL) return process.env.SUPABASE_DB_URL;
  if (!fs.existsSync(ENV_FILE)) return null;
  for (const line of fs.readFileSync(ENV_FILE, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*SUPABASE_DB_URL\s*=\s*(.+)\s*$/);
    if (m) return m[1].trim().replace(/^["']|["']$/g, '');
  }
  return null;
}

// Never log the password, whatever happens.
const scrub = (s) => String(s || '').replace(/:\/\/[^@]*@/, '://****:****@');

(async () => {
  const url = readEnv();
  if (!url) {
    console.error(`
Missing SUPABASE_DB_URL.

Add it as a single line to .env.local (already git-ignored):

  SUPABASE_DB_URL=postgresql://postgres.<ref>:<password>@<host>:5432/postgres

Get it from: Supabase -> Project Settings -> Database -> Connection string
-> URI. Copy the "Session pooler" or "Direct connection" URI and put your
database password in place of [YOUR-PASSWORD].
`);
    process.exit(1);
  }

  if (!fs.existsSync(SQL_FILE)) {
    console.error('Missing ' + SQL_FILE);
    process.exit(1);
  }
  const sql = fs.readFileSync(SQL_FILE, 'utf8');

  const client = new Client({
    connectionString: url,
    ssl: { rejectUnauthorized: false },
    statement_timeout: 300000,
  });

  try {
    await client.connect();
  } catch (e) {
    console.error('Could not connect:', e.message);
    console.error('Using:', scrub(url));
    process.exit(1);
  }

  const who = await client.query('select current_database() db, current_user usr, version() v');
  console.log('Connected to', who.rows[0].db, 'as', who.rows[0].usr);
  console.log(who.rows[0].v.split(',')[0]);
  console.log('SQL file:', path.basename(SQL_FILE), '-', sql.split('\n').length, 'lines\n');

  if (DRY) {
    console.log('--dry-run: connection verified, nothing executed.');
    await client.end();
    return;
  }

  // One transaction. All of it lands, or none of it does.
  try {
    await client.query('begin');
    await client.query(sql);
    await client.query('commit');
    console.log('MIGRATION COMMITTED — all seven migrations applied.\n');
  } catch (e) {
    await client.query('rollback').catch(() => {});
    console.error('MIGRATION FAILED — rolled back, database unchanged.\n');
    console.error('  error:  ', e.message);
    if (e.position) {
      const pos = parseInt(e.position, 10);
      const before = sql.slice(0, pos);
      const line = before.split('\n').length;
      console.error('  line:   ', line, 'of supabase-RUN-ALL.sql');
      console.error('  context:\n');
      const lines = sql.split('\n');
      for (let i = Math.max(0, line - 4); i < Math.min(lines.length, line + 3); i++) {
        console.error(String(i + 1).padStart(6), i + 1 === line ? '>' : ' ', lines[i]);
      }
    }
    if (e.detail) console.error('\n  detail: ', e.detail);
    if (e.hint) console.error('  hint:   ', e.hint);
    await client.end();
    process.exit(1);
  }

  // Post-run verification — the same checks I would have asked you to paste.
  const checks = [
    ['Roles', `select role_key, department, designation, count(*)::int n
               from public.profiles group by 1,2,3 order by 1`],
    ['Teams', `select name, department from public.teams order by department, name`],
    ['Unplaced sales/kam', `select name, email, role_key from public.profiles
               where team_uid is null and department in ('sales','kam') order by name`],
    ['Tables', `select table_name from information_schema.tables
               where table_schema='public' and table_name in
               ('requests','enquiries','roster','brand_sheets','teams','audit_log','brands','kv')
               order by 1`],
    ['Row counts', `select 'requests' t, count(*)::int n from public.requests
               union all select 'enquiries', count(*)::int from public.enquiries
               union all select 'roster', count(*)::int from public.roster
               union all select 'brand_sheets', count(*)::int from public.brand_sheets`],
  ];

  for (const [label, q] of checks) {
    try {
      const r = await client.query(q);
      console.log('--- ' + label + ' ---');
      console.table(r.rows);
    } catch (e) {
      console.log('--- ' + label + ' --- failed:', e.message);
    }
  }

  await client.end();
  console.log('\nDone. Next: place the unplaced Sales/KAM users into TPA vs MHS.');
})();
