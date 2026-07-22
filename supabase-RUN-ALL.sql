-- ============================================================
-- DiscoverDesk — RUN ALL MIGRATIONS (generated, do not hand-edit)
--
-- Paste this entire file into Supabase -> SQL Editor -> Run.
-- The seven migrations below are concatenated in DEPENDENCY ORDER.
-- Every one is idempotent, so if the script aborts partway you can fix
-- the offending statement and simply run the whole file again.
--
-- ORDER MATTERS:
--   requests/enquiries must exist before the Section A policies reference
--   them; teams must exist before Section B's owner_team_id FK; audit_log
--   and brand_sheets must exist before Section C.
--
-- AFTER RUNNING, EXPECT THIS:
--   Sales and KAM users have NO team yet (nothing in the existing data says
--   who is TPA vs MHS, and the sprint said do not guess). Until you place
--   them, each sees only themselves on Team & Departments. Fix it in
--   People & Access -> Teams, or with SQL:
--     update public.profiles set team_uid =
--       (select id from public.teams where name='TPA Sales')
--     where email in ('...','...');
--
--   Find who still needs placing:
--     select name, email, role_key from public.profiles
--     where team_uid is null and department in ('sales','kam');
-- ============================================================







-- ############################################################
-- ## supabase-requests-migration.sql
-- ## Stage 1 - requests table + profiles.team_id
-- ############################################################

-- ============================================================
-- DiscoverDesk — Stage 1: real `requests` table + team/role isolation
-- Paste ALL of this into Supabase → SQL Editor → Run.
-- Safe to re-run (uses IF NOT EXISTS / OR REPLACE / drop-then-create policies,
-- and the one-time migration at the bottom is idempotent via ON CONFLICT).
--
-- WHAT THIS DOES
--  1. Adds a team_id column to profiles.
--  2. Creates a real `requests` table (one row per request) with RLS:
--     admins see everything; everyone else sees rows where they are the
--     owner, the assignee, or share a team with the owner.
--  3. Copies every request currently sitting inside the `kv` blob
--     (key 'dd:requests') into the new table.
--
-- IMPORTANT — READ BEFORE RUNNING
--  Nobody has a team assigned yet, so step 1 puts every existing profile
--  into a single 'default' team. That preserves today's visibility (nobody
--  loses access the moment this goes live). Once you're ready to actually
--  split people into teams, run:
--    update public.profiles set team_id = 'sales-a' where email in (...);
--  Note this is a real behavior change vs. today: some roles (sales/kam/
--  manager) currently see ALL requests platform-wide via a 'review'
--  permission — after this migration, that permission no longer grants
--  DB-level visibility outside someone's own team/assignments. Only the
--  'admin' role still sees everything. Re-team people (or make them admin)
--  if you need that wider visibility preserved.
-- ============================================================

-- 1) Team membership on profiles
alter table public.profiles add column if not exists team_id text;
update public.profiles set team_id = 'default' where team_id is null;

-- 2) Safe uuid cast helper (request owner/assignee ids come from JSON that
--    may occasionally be missing or malformed — never let one bad row
--    abort the whole migration)
create or replace function public.safe_uuid(t text) returns uuid
  language sql immutable as $$
    select case
      when t ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then t::uuid else null end
  $$;

-- 3) requests table
create table if not exists public.requests (
  id          text primary key,
  team_id     text,
  owner_id    uuid references auth.users on delete set null,
  assignee_id uuid references auth.users on delete set null,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
alter table public.requests enable row level security;

create or replace function public.touch_updated_at() returns trigger
  language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_requests_touch on public.requests;
create trigger trg_requests_touch before update on public.requests
  for each row execute function public.touch_updated_at();

-- 4) RLS — admin sees everything; everyone else sees own + assigned + same team
drop policy if exists req_select on public.requests;
drop policy if exists req_insert on public.requests;
drop policy if exists req_update on public.requests;
drop policy if exists req_delete on public.requests;

create policy req_select on public.requests for select using (
  public.is_admin()
  or owner_id = auth.uid()
  or assignee_id = auth.uid()
  or (team_id is not null and team_id = (select p.team_id from public.profiles p where p.id = auth.uid()))
);

create policy req_insert on public.requests for insert with check (
  public.is_active()
);

create policy req_update on public.requests for update using (
  public.is_admin()
  or owner_id = auth.uid()
  or assignee_id = auth.uid()
  or (team_id is not null and team_id = (select p.team_id from public.profiles p where p.id = auth.uid()))
) with check (
  public.is_admin()
  or owner_id = auth.uid()
  or assignee_id = auth.uid()
  or (team_id is not null and team_id = (select p.team_id from public.profiles p where p.id = auth.uid()))
);

-- Only admins can hard-delete a request row.
create policy req_delete on public.requests for delete using (
  public.is_admin()
);

-- 5) Realtime — index.html listens on this table directly
do $$ begin
  alter publication supabase_realtime add table public.requests;
exception when duplicate_object then null;
end $$;

-- 6) ONE-TIME MIGRATION — copy requests out of the kv blob.
--    Safe to run more than once: existing rows are refreshed, not duplicated.
insert into public.requests (id, team_id, owner_id, assignee_id, data, created_at)
select distinct on (r->>'id')
  r->>'id' as id,
  coalesce(
    (select p.team_id from public.profiles p where p.id = public.safe_uuid(r->>'requesterId')),
    'default'
  ) as team_id,
  public.safe_uuid(r->>'requesterId') as owner_id,
  public.safe_uuid(r->>'assigneeId') as assignee_id,
  r as data,
  case when (r->>'createdAt') is not null
       then to_timestamp((r->>'createdAt')::bigint/1000.0)
       else now() end as created_at
from public.kv, jsonb_array_elements(coalesce(value,'[]'::jsonb)) as r
where key = 'dd:requests' and r->>'id' is not null
on conflict (id) do update set
  team_id     = excluded.team_id,
  owner_id    = excluded.owner_id,
  assignee_id = excluded.assignee_id,
  data        = excluded.data;

-- Done. The old 'dd:requests' key in kv is left untouched as a backup —
-- index.html no longer reads or writes it once the app-side change is live.
-- Once you've confirmed everything works, you can optionally clear it with:
--   update public.kv set value = '[]'::jsonb where key = 'dd:requests';


-- ############################################################
-- ## supabase-enquiries-migration.sql
-- ## Stage 2 - enquiries table
-- ############################################################

-- ============================================================
-- DiscoverDesk — Stage 2: real `enquiries` table + team/role isolation
-- Paste ALL of this into Supabase → SQL Editor → Run.
-- Run this AFTER supabase-requests-migration.sql (Stage 1), which is what
-- adds profiles.team_id. Safe to re-run.
--
-- WHAT THIS DOES
--  1. Creates a real `enquiries` table (one row per enquiry) with RLS:
--     admins see everything; everyone else sees rows they own or that
--     belong to their team.
--  2. Copies every enquiry currently sitting inside the `kv` blob
--     (key 'dd:enquiries') into the new table.
--
-- BEHAVIOUR CHANGE — READ THIS
--  Today any active user can read the whole kv blob, so everyone sees every
--  enquiry. After this runs, a sales/kam/manager user sees only their own
--  enquiries plus their team's. The 'enquiries' permission still controls
--  whether they can use the module at all, but it no longer grants
--  DB-level visibility of other teams' pipeline. Only 'admin' sees all.
--  Stage 1 put everyone in team 'default', so nothing disappears on day
--  one — visibility narrows only once you actually split people into teams.
-- ============================================================

-- 0) Safety net: Stage 1 should already have done this. Harmless if so.
alter table public.profiles add column if not exists team_id text;
update public.profiles set team_id = 'default' where team_id is null;

create or replace function public.safe_uuid(t text) returns uuid
  language sql immutable as $$
    select case
      when t ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      then t::uuid else null end
  $$;

-- 1) enquiries table
create table if not exists public.enquiries (
  id         text primary key,
  team_id    text,
  owner_id   uuid references auth.users on delete set null,
  data       jsonb not null default '{}'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table public.enquiries enable row level security;

create or replace function public.touch_updated_at() returns trigger
  language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_enquiries_touch on public.enquiries;
create trigger trg_enquiries_touch before update on public.enquiries
  for each row execute function public.touch_updated_at();

create index if not exists enquiries_owner_idx on public.enquiries(owner_id);
create index if not exists enquiries_team_idx  on public.enquiries(team_id);

-- 2) RLS — admin sees everything; everyone else sees own + same team
drop policy if exists enq_select on public.enquiries;
drop policy if exists enq_insert on public.enquiries;
drop policy if exists enq_update on public.enquiries;
drop policy if exists enq_delete on public.enquiries;

create policy enq_select on public.enquiries for select using (
  public.is_admin()
  or owner_id = auth.uid()
  or (team_id is not null and team_id = (select p.team_id from public.profiles p where p.id = auth.uid()))
);

create policy enq_insert on public.enquiries for insert with check (
  public.is_active()
);

create policy enq_update on public.enquiries for update using (
  public.is_admin()
  or owner_id = auth.uid()
  or (team_id is not null and team_id = (select p.team_id from public.profiles p where p.id = auth.uid()))
) with check (
  public.is_admin()
  or owner_id = auth.uid()
  or (team_id is not null and team_id = (select p.team_id from public.profiles p where p.id = auth.uid()))
);

-- Only admins can hard-delete an enquiry.
create policy enq_delete on public.enquiries for delete using (
  public.is_admin()
);

-- 3) Realtime — index.html listens on this table directly
do $$ begin
  alter publication supabase_realtime add table public.enquiries;
exception when duplicate_object then null;
end $$;

-- 4) ONE-TIME MIGRATION — copy enquiries out of the kv blob.
--    Safe to run more than once: existing rows are refreshed, not duplicated.
insert into public.enquiries (id, team_id, owner_id, data, created_at)
select distinct on (e->>'id')
  e->>'id' as id,
  coalesce(
    (select p.team_id from public.profiles p where p.id = public.safe_uuid(e->>'ownerId')),
    'default'
  ) as team_id,
  public.safe_uuid(e->>'ownerId') as owner_id,
  e as data,
  case when (e->>'createdAt') is not null
       then to_timestamp((e->>'createdAt')::bigint/1000.0)
       else now() end as created_at
from public.kv, jsonb_array_elements(coalesce(value,'[]'::jsonb)) as e
where key = 'dd:enquiries' and e->>'id' is not null
on conflict (id) do update set
  team_id  = excluded.team_id,
  owner_id = excluded.owner_id,
  data     = excluded.data;

-- Done. The old 'dd:enquiries' key in kv is left untouched as a backup —
-- index.html no longer reads or writes it once the app-side change is live.
-- Once you've confirmed everything works you can optionally clear it with:
--   update public.kv set value = '[]'::jsonb where key = 'dd:enquiries';


-- ############################################################
-- ## supabase-roster-migration.sql
-- ## Stage 3 - roster + contact masking
-- ############################################################

-- ============================================================
-- DiscoverDesk — Stage 3: real `roster` table + DB-enforced contact hiding
-- Paste ALL of this into Supabase → SQL Editor → Run.
-- Run AFTER Stage 1 (requests) and Stage 2 (enquiries). Safe to re-run.
--
-- WHAT THIS DOES
--  1. Creates a real `roster` table, splitting each creator into:
--       data    jsonb — everything except email/phone
--       contact jsonb — {email, phone}
--  2. LOCKS the base table: `authenticated` gets NO direct access to it.
--     Reads go through the view `roster_v`, which returns `contact` only
--     when the caller actually holds the 'contacts' permission. A user
--     without it cannot see phone/email even by calling the REST API
--     directly — the masking is in the database, not the UI.
--  3. Writes go through the `roster_sync` RPC, which REFUSES to overwrite
--     the contact fields for callers who can't see them. Without this, a
--     no-contacts user loading masked data and hitting save would blank
--     out everyone's phone/email.
--  4. Copies the existing roster out of the `kv` blob.
--
-- WHY A VIEW + RPC AND NOT PLAIN RLS
--  RLS is row-level. "Hide two columns from some users" is column-level,
--  which RLS cannot express — hence the locked table + masking view.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Permission helpers — mirror of ROLE_DEFAULTS / can() in index.html.
--    Keep these in sync if you change role defaults in the app.
-- ------------------------------------------------------------
create or replace function public.role_defaults(r text) returns jsonb
  language sql immutable as $$
    select case r
      when 'sales'     then '{"raise":1,"enquiries":1,"review":1,"influencers":0,"clientview":1,"brandcost":1,"export":1,"poolfill":1}'::jsonb
      when 'kam'       then '{"raise":1,"enquiries":1,"review":1,"influencers":1,"roster":1,"clientview":1,"contacts":1,"brandcost":1,"export":1,"poolfill":1}'::jsonb
      when 'discovery' then '{"discover":1,"influencers":1,"roster":1,"export":1,"poolfill":1}'::jsonb
      when 'manager'   then '{"raise":1,"enquiries":1,"assign":1,"review":1,"discover":1,"influencers":1,"roster":1,"clientview":1,"contacts":1,"brandcost":1,"export":1,"poolfill":1}'::jsonb
      when 'admin'     then '{"raise":1,"enquiries":1,"assign":1,"discover":1,"review":1,"influencers":1,"roster":1,"bridge":1,"brandcost":1,"clientview":1,"contacts":1,"export":1,"integrations":1,"admin":1,"poolfill":1}'::jsonb
      else '{}'::jsonb end
  $$;

-- Same precedence as can() in the app: an explicit per-user override wins,
-- otherwise fall back to the role default. Only active users hold anything.
create or replace function public.has_perm(p text) returns boolean
  language sql stable security definer set search_path = public as $$
    select coalesce((
      select case
        when pr.perms ? p and jsonb_typeof(pr.perms -> p) <> 'null'
          then (pr.perms ->> p) not in ('0','false')
        else coalesce((public.role_defaults(pr.role) ->> p) not in ('0','false'), false)
      end
      from public.profiles pr
      where pr.id = auth.uid() and pr.status = 'active'
    ), false);
  $$;

create or replace function public.safe_epoch(t text) returns timestamptz
  language sql immutable as $$
    select case when t ~ '^[0-9]{1,15}$'
                then to_timestamp(t::bigint / 1000.0)
                else now() end
  $$;

-- ------------------------------------------------------------
-- 2) The roster table (base table — deliberately NOT reachable by clients)
-- ------------------------------------------------------------
create table if not exists public.roster (
  id         text primary key,
  data       jsonb not null default '{}'::jsonb,   -- everything except email/phone
  contact    jsonb not null default '{}'::jsonb,   -- {email, phone} — masked on read
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table public.roster enable row level security;

create or replace function public.touch_updated_at() returns trigger
  language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_roster_touch on public.roster;
create trigger trg_roster_touch before update on public.roster
  for each row execute function public.touch_updated_at();

-- No policies are created for `roster`, and RLS is on: with RLS enabled and
-- zero policies, every direct client query returns nothing. Belt and braces,
-- we also drop the table-level grants. Only SECURITY DEFINER code (the view
-- and the sync RPC, both owned by postgres) can reach the real rows.
revoke all on public.roster from anon, authenticated;

-- ------------------------------------------------------------
-- 3) The masking view — this is what the app reads
-- ------------------------------------------------------------
-- NOTE: this view intentionally runs with the *owner's* rights (the Postgres
-- default, security_invoker = false) so it can read the locked base table.
-- Supabase's linter flags that as "security definer view" — here it is the
-- whole point. The view does its own authorization in the WHERE clause.
drop view if exists public.roster_v;
create view public.roster_v as
  select
    r.id,
    r.data,
    case when public.has_perm('contacts') then r.contact else '{}'::jsonb end as contact,
    public.has_perm('contacts') as contact_visible,
    r.created_at,
    r.updated_at
  from public.roster r
  where public.is_active();

grant select on public.roster_v to authenticated;

-- ------------------------------------------------------------
-- 4) Writes — one RPC that upserts a batch and deletes removed ids.
--    Contact fields are preserved (never blanked) for callers who can't
--    see them.
-- ------------------------------------------------------------
create or replace function public.roster_sync(p_rows jsonb, p_removed text[] default '{}')
  returns integer
  language plpgsql security definer set search_path = public as $$
declare
  n integer := 0;
  can_contacts boolean := public.has_perm('contacts');
begin
  if not public.is_active() then
    raise exception 'roster_sync: not an active user';
  end if;

  -- Deliberately NOT gated on the 'roster' permission. The roster blob is
  -- written as a side effect of flows that non-roster users legitimately
  -- run — updateRevCount() in the review/rounds flow and creatorNoteSave()
  -- both call save('roster'), and a sales user can reach both. Gating writes
  -- here would break reviews for them.
  --
  -- That costs nothing in confidentiality: the contact fields are the
  -- sensitive part, and the ON CONFLICT clause below refuses to let a
  -- caller who cannot READ them overwrite them. Everything else in the
  -- roster is already readable by every active user.

  if p_rows is not null and jsonb_typeof(p_rows) = 'array' then
    -- distinct on: ON CONFLICT cannot touch the same row twice in one
    -- statement, so a duplicate id inside the batch would abort the save.
    insert into public.roster (id, data, contact)
    select distinct on (x->>'id')
      x->>'id',
      coalesce(x->'data', '{}'::jsonb),
      coalesce(x->'contact', '{}'::jsonb)
    from jsonb_array_elements(p_rows) as x
    where x->>'id' is not null
    on conflict (id) do update set
      data = excluded.data,
      -- The important line: a caller who cannot READ contacts cannot
      -- OVERWRITE them either. Their masked payload is ignored.
      contact = case when can_contacts then excluded.contact
                     else roster.contact end;
    get diagnostics n = row_count;
  end if;

  if p_removed is not null and array_length(p_removed, 1) > 0 then
    delete from public.roster where id = any(p_removed);
  end if;

  -- Nudge the kv table so other browsers' realtime subscription fires and
  -- they reload. The roster table itself is deliberately kept out of the
  -- realtime publication — realtime payloads bypass the masking view and
  -- would ship raw contact rows to every subscriber.
  insert into public.kv (key, value) values ('dd:rosterver', to_jsonb(extract(epoch from now())))
  on conflict (key) do update set value = excluded.value;

  return n;
end $$;

revoke all on function public.roster_sync(jsonb, text[]) from anon;
grant execute on function public.roster_sync(jsonb, text[]) to authenticated;

-- ------------------------------------------------------------
-- 5) ONE-TIME MIGRATION — split the kv roster blob into data + contact.
--    Safe to run more than once.
-- ------------------------------------------------------------
insert into public.roster (id, data, contact, created_at)
select distinct on (r->>'id')
  r->>'id',
  (r - 'email' - 'phone') as data,
  jsonb_strip_nulls(jsonb_build_object(
    'email', r->>'email',
    'phone', r->>'phone'
  )) as contact,
  public.safe_epoch(r->>'addedAt') as created_at
from public.kv, jsonb_array_elements(coalesce(value,'[]'::jsonb)) as r
where key = 'dd:roster' and r->>'id' is not null
on conflict (id) do update set
  data    = excluded.data,
  contact = excluded.contact;

-- ------------------------------------------------------------
-- 6) Verify the masking actually works
-- ------------------------------------------------------------
-- As an admin/kam/manager (has 'contacts'):
--   select id, contact, contact_visible from public.roster_v limit 5;
--   -> contact populated, contact_visible = true
-- As a sales/discovery user (no 'contacts'):
--   -> contact = {}, contact_visible = false
-- And the base table is unreachable either way:
--   select * from public.roster;   -> permission denied
--
-- The old 'dd:roster' key in kv is left untouched as a backup. Once you're
-- happy, clear it with:
--   update public.kv set value = '[]'::jsonb where key = 'dd:roster';


-- ############################################################
-- ## supabase-brandsheets-migration.sql
-- ## Stage 5 - brand_sheets (fixes edit loss)
-- ############################################################

-- ============================================================
-- DiscoverDesk — Stage 5: real `brand_sheets` table
-- Paste ALL of this into Supabase → SQL Editor → Run. Safe to re-run.
--
-- WHY THIS EXISTS (this is a bug fix, not just isolation work)
--  db.infl in index.html holds BRAND SHEETS — per-brand/per-campaign working
--  lists of creators, shaped {id, brandId, campaignId, handle, status, ...}.
--  A previous change pointed its LOAD at the `influencers` master creator
--  table, which has no brand_id/campaign_id columns and a totally different
--  shape. The WRITE was never repointed, so save('infl') kept writing to the
--  kv key 'dd:influencers' — a key cloud mode no longer reads.
--
--  Net effect in production: brand sheets load as the wrong data, and every
--  edit, bulk status change, import and delete is lost on the next reload.
--
--  This table gives brand sheets their own home, with the shape they
--  actually have. The `influencers` master table is left alone — it is a
--  separate concern (the global creator database).
--
-- VISIBILITY
--  Deliberately readable by every active user, which is exactly what the kv
--  blob did today. This migration is a data-loss fix and intentionally does
--  NOT change who can see what — narrowing brand-sheet visibility is a
--  separate decision, since discovery/sales/kam collaborate on these lists
--  across teams. team_id is recorded now so you can tighten it later.
-- ============================================================

create table if not exists public.brand_sheets (
  id          text primary key,
  team_id     text,
  brand_id    text,
  campaign_id text,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
alter table public.brand_sheets enable row level security;

create or replace function public.touch_updated_at() returns trigger
  language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_brand_sheets_touch on public.brand_sheets;
create trigger trg_brand_sheets_touch before update on public.brand_sheets
  for each row execute function public.touch_updated_at();

create index if not exists brand_sheets_brand_idx on public.brand_sheets(brand_id);
create index if not exists brand_sheets_camp_idx  on public.brand_sheets(campaign_id);

-- RLS — same reach the kv blob had: any active user.
drop policy if exists bs_select on public.brand_sheets;
drop policy if exists bs_insert on public.brand_sheets;
drop policy if exists bs_update on public.brand_sheets;
drop policy if exists bs_delete on public.brand_sheets;

create policy bs_select on public.brand_sheets for select using (public.is_active());
create policy bs_insert on public.brand_sheets for insert with check (public.is_active());
create policy bs_update on public.brand_sheets for update using (public.is_active())
  with check (public.is_active());
-- delInfl / bulkDelInfl are used by discovery and kam users, not just admins.
create policy bs_delete on public.brand_sheets for delete using (public.is_active());

-- Realtime
do $$ begin
  alter publication supabase_realtime add table public.brand_sheets;
exception when duplicate_object then null;
end $$;

-- ONE-TIME MIGRATION — recover the brand sheets still sitting in kv.
-- This is the data your team's recent edits were being written to.
insert into public.brand_sheets (id, team_id, brand_id, campaign_id, data, created_at)
select distinct on (i->>'id')
  i->>'id',
  'default',
  i->>'brandId',
  i->>'campaignId',
  i,
  case when (i->>'addedAt') ~ '^[0-9]{1,15}$'
       then to_timestamp((i->>'addedAt')::bigint/1000.0)
       else now() end
from public.kv, jsonb_array_elements(coalesce(value,'[]'::jsonb)) as i
where key = 'dd:influencers' and i->>'id' is not null
on conflict (id) do update set
  brand_id    = excluded.brand_id,
  campaign_id = excluded.campaign_id,
  data        = excluded.data;

-- Check what came back:
--   select count(*) from public.brand_sheets;


-- ############################################################
-- ## supabase-rbac-migration.sql
-- ## Section A - roles, teams, visibility matrix
-- ############################################################

-- ============================================================
-- DiscoverDesk — Section A: department/designation roles, teams, RLS matrix
-- Paste ALL of this into Supabase → SQL Editor → Run. Safe to re-run.
--
-- ADDITIVE BY DESIGN. Nothing is dropped and no existing column is retyped:
--   profiles.role      (text, old 5-role) — LEFT IN PLACE, still backfilled
--   profiles.role_key  (text, new 7-role) — added, backfilled from role
--   profiles.department / designation     — added, derived from role_key
--   profiles.team_id   (text, from Stage 1) — LEFT IN PLACE, untouched
--   profiles.team_uid  (uuid -> teams.id)   — added, the real team link
-- Reads switch to the new columns; the old ones can be dropped in a later
-- migration once you're happy. This follows the sprint's own
-- add → backfill → switch reads → drop-later rule.
--
-- ROLE MAP (A1)
--   sales     -> sales_employee        kam      -> kam_employee
--   discovery -> discovery_employee    manager  -> discovery_manager
--   admin     -> admin
-- "employee", never "executive".
-- ============================================================

-- ------------------------------------------------------------
-- A1) Role columns
-- ------------------------------------------------------------
alter table public.profiles add column if not exists role_key    text;
alter table public.profiles add column if not exists department  text;
alter table public.profiles add column if not exists designation text;

-- Backfill. Only fills what is still null, so re-running never clobbers a
-- role someone has since changed by hand.
update public.profiles set role_key = case role
    when 'sales'     then 'sales_employee'
    when 'kam'       then 'kam_employee'
    when 'discovery' then 'discovery_employee'
    when 'manager'   then 'discovery_manager'
    when 'admin'     then 'admin'
    else 'sales_employee'
  end
where role_key is null;

-- department / designation are always derived from role_key — keep them in
-- lockstep so policies can read either without drifting.
update public.profiles set
  department = case
    when role_key like 'sales%'     then 'sales'
    when role_key like 'kam%'       then 'kam'
    when role_key like 'discovery%' then 'discovery'
    else 'admin' end,
  designation = case
    when role_key = 'admin'       then 'admin'
    when role_key like '%_manager' then 'manager'
    else 'employee' end;

alter table public.profiles drop constraint if exists profiles_role_key_chk;
alter table public.profiles add constraint profiles_role_key_chk check (
  role_key in ('sales_manager','sales_employee','kam_manager','kam_employee',
               'discovery_manager','discovery_employee','admin')
);

-- Keep the legacy `role` column consistent for any code still reading it,
-- so the two never disagree during the transition.
create or replace function public.sync_legacy_role() returns trigger
  language plpgsql as $$
begin
  if new.role_key is not null then
    new.department := case
      when new.role_key like 'sales%'     then 'sales'
      when new.role_key like 'kam%'       then 'kam'
      when new.role_key like 'discovery%' then 'discovery'
      else 'admin' end;
    new.designation := case
      when new.role_key = 'admin'        then 'admin'
      when new.role_key like '%_manager' then 'manager'
      else 'employee' end;
    new.role := case new.role_key
      when 'sales_manager'      then 'sales'
      when 'sales_employee'     then 'sales'
      when 'kam_manager'        then 'kam'
      when 'kam_employee'       then 'kam'
      when 'discovery_manager'  then 'manager'
      when 'discovery_employee' then 'discovery'
      else 'admin' end;
  end if;
  return new;
end $$;
drop trigger if exists trg_profiles_sync_role on public.profiles;
create trigger trg_profiles_sync_role before insert or update on public.profiles
  for each row execute function public.sync_legacy_role();

-- ------------------------------------------------------------
-- A2) Teams
-- ------------------------------------------------------------
create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  department text not null,
  manager_id uuid null references public.profiles(id) on delete set null,
  created_at timestamptz default now(),
  unique (name, department)
);
alter table public.teams enable row level security;

insert into public.teams (name, department) values
  ('TPA Sales','sales'), ('MHS Sales','sales'),
  ('TPA KAM','kam'),     ('MHS KAM','kam')
on conflict (name, department) do nothing;

-- Discovery is a single team, not split TPA/MHS.
insert into public.teams (name, department) values ('Discovery','discovery')
on conflict (name, department) do nothing;

alter table public.profiles add column if not exists team_uid uuid
  references public.teams(id) on delete set null;
create index if not exists profiles_team_uid_idx on public.profiles(team_uid);
create index if not exists profiles_dept_idx     on public.profiles(department);

-- Backfill: every discovery user goes to the single Discovery team. Sales and
-- KAM are NOT guessed — there is nothing in the existing data that says who
-- is TPA and who is MHS, and the sprint says do not guess. They stay null and
-- surface in the "Unassigned" bucket for you to place by hand.
update public.profiles p set team_uid = t.id
from public.teams t
where t.department = 'discovery' and p.department = 'discovery' and p.team_uid is null;

-- ------------------------------------------------------------
-- A4) Helper functions — SECURITY DEFINER, fixed search_path
-- ------------------------------------------------------------
create or replace function public.current_role_key() returns text
  language sql stable security definer set search_path = public as $$
    select role_key from public.profiles where id = auth.uid() and status = 'active'
  $$;

create or replace function public.current_department() returns text
  language sql stable security definer set search_path = public as $$
    select department from public.profiles where id = auth.uid() and status = 'active'
  $$;

create or replace function public.current_team_id() returns uuid
  language sql stable security definer set search_path = public as $$
    select team_uid from public.profiles where id = auth.uid() and status = 'active'
  $$;

create or replace function public.is_admin() returns boolean
  language sql stable security definer set search_path = public as $$
    select exists(select 1 from public.profiles
                  where id = auth.uid() and status = 'active'
                    and (role_key = 'admin' or role = 'admin'))
  $$;

create or replace function public.is_manager() returns boolean
  language sql stable security definer set search_path = public as $$
    select exists(select 1 from public.profiles
                  where id = auth.uid() and status = 'active'
                    and designation in ('manager','admin'))
  $$;

-- The team of a given record's owner. Defined before the policies below,
-- which depend on it.
create or replace function public.team_uid_of_owner(o uuid) returns uuid
  language sql stable security definer set search_path = public as $$
    select team_uid from public.profiles where id = o
  $$;

-- ------------------------------------------------------------
-- A3) Visibility matrix
--
--  Viewer               people              enquiries                requests
--  admin                everyone            all                      all
--  sales_manager        own team            own team's               own team's
--  sales_employee       own team            own (owner = self)       own (owner = self)
--  kam_manager          own team            own team's               own team's
--  kam_employee         own team            own                      own
--  discovery_manager    own department      converted to requests    all
--  discovery_employee   own team            none                     assigned = self
-- ------------------------------------------------------------

-- PROFILES: nobody sees another department's people except admin.
drop policy if exists p_select on public.profiles;
-- Falls back to the department when either side has no team yet: Sales/KAM
-- are deliberately unplaced after the backfill, and a strict team check would
-- collapse the page to just yourself. The hard rule -- nobody sees another
-- department except Admin -- still holds either way.
create policy p_select on public.profiles for select using (
  public.is_admin()
  or id = auth.uid()                                   -- always see yourself
  or (public.current_role_key() = 'discovery_manager'  -- whole Discovery dept
      and department = 'discovery')
  or (team_uid is not null and team_uid = public.current_team_id())
  or ((team_uid is null or public.current_team_id() is null)
      and department = public.current_department())
);

-- TEAMS: readable by any active user (needed to render team names); only
-- admins may create/rename/reassign.
drop policy if exists t_select on public.teams;
drop policy if exists t_write  on public.teams;
create policy t_select on public.teams for select using (public.is_active());
create policy t_write  on public.teams for all
  using (public.is_admin()) with check (public.is_admin());

-- REQUESTS. owner_id = the Sales/KAM owner; assignee_id = discovery employee.
drop policy if exists req_select on public.requests;
create policy req_select on public.requests for select using (
  public.is_admin()
  or public.current_role_key() = 'discovery_manager'          -- all requests
  or (public.current_role_key() = 'discovery_employee'        -- only assigned
      and assignee_id = auth.uid())
  or (public.current_role_key() in ('sales_employee','kam_employee')
      and owner_id = auth.uid())                              -- own only
  or (public.current_role_key() in ('sales_manager','kam_manager')
      and public.team_uid_of_owner(owner_id) = public.current_team_id())
);

drop policy if exists req_update on public.requests;
create policy req_update on public.requests for update using (
  public.is_admin()
  or public.current_role_key() = 'discovery_manager'
  or owner_id = auth.uid()
  or assignee_id = auth.uid()
) with check (
  public.is_admin()
  or public.current_role_key() = 'discovery_manager'
  or owner_id = auth.uid()
  or assignee_id = auth.uid()
);

-- ENQUIRIES.
drop policy if exists enq_select on public.enquiries;
create policy enq_select on public.enquiries for select using (
  public.is_admin()
  or (public.current_role_key() in ('sales_employee','kam_employee')
      and owner_id = auth.uid())
  or (public.current_role_key() in ('sales_manager','kam_manager')
      and public.team_uid_of_owner(owner_id) = public.current_team_id())
  or (public.current_role_key() = 'discovery_manager'
      and (data ? 'convertedRequestId' or coalesce(data->>'status','') = 'won'))
  -- discovery_employee: no enquiry access at all.
);

drop policy if exists enq_update on public.enquiries;
create policy enq_update on public.enquiries for update using (
  public.is_admin() or owner_id = auth.uid()
) with check (
  public.is_admin() or owner_id = auth.uid()
);

-- ------------------------------------------------------------
-- Verify
-- ------------------------------------------------------------
-- select role, role_key, department, designation, count(*)
--   from public.profiles group by 1,2,3,4 order by 1;
--
-- Users with no team (place these by hand in People & Access):
-- select id, name, email, role_key, department from public.profiles
--   where team_uid is null and department in ('sales','kam') order by department, name;


-- ############################################################
-- ## supabase-assignment-migration.sql
-- ## Section B - two-hop, ownership, clock, audit_log
-- ############################################################

-- ============================================================
-- DiscoverDesk — Section B: two-hop assignment, immutable ownership,
-- discovery-clock ownership.
-- Run AFTER supabase-rbac-migration.sql. Safe to re-run.
-- ============================================================

-- ------------------------------------------------------------
-- B6) Two-hop assignment columns
--   Hop 1  Sales/KAM -> Discovery Manager   (routed_*)
--   Hop 2  Discovery Manager -> Discovery Employee (assigned_*)
-- ------------------------------------------------------------
alter table public.requests add column if not exists owner_team_id        uuid references public.teams(id) on delete set null;
alter table public.requests add column if not exists routed_to_manager_id uuid references auth.users on delete set null;
alter table public.requests add column if not exists routed_by_id         uuid references auth.users on delete set null;
alter table public.requests add column if not exists routed_at            timestamptz;
alter table public.requests add column if not exists assigned_to_id       uuid references auth.users on delete set null;
alter table public.requests add column if not exists assigned_by_id       uuid references auth.users on delete set null;
alter table public.requests add column if not exists assigned_at          timestamptz;

create index if not exists requests_assigned_to_idx on public.requests(assigned_to_id);
create index if not exists requests_owner_idx       on public.requests(owner_id);
create index if not exists requests_routed_idx      on public.requests(routed_to_manager_id);
create index if not exists enquiries_owner_idx2     on public.enquiries(owner_id);

-- Backfill from the columns that already exist.
update public.requests set assigned_to_id = assignee_id where assigned_to_id is null and assignee_id is not null;
update public.requests p set owner_team_id = pr.team_uid
  from public.profiles pr where pr.id = p.owner_id and p.owner_team_id is null;

-- Role of a given user, for the constraint triggers below.
create or replace function public.role_key_of(u uuid) returns text
  language sql stable security definer set search_path = public as $$
    select role_key from public.profiles where id = u
  $$;

-- Enforce BOTH hop targets at the database, so a malformed insert fails here
-- and not only in the API (sprint B6, last bullet).
create or replace function public.enforce_assignment_targets() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.routed_to_manager_id is not null
     and public.role_key_of(new.routed_to_manager_id) is distinct from 'discovery_manager' then
    raise exception 'routed_to_manager_id must reference a discovery_manager (got %)',
      coalesce(public.role_key_of(new.routed_to_manager_id),'unknown');
  end if;

  if new.assigned_to_id is not null
     and public.role_key_of(new.assigned_to_id) is distinct from 'discovery_employee' then
    raise exception 'assigned_to_id must reference a discovery_employee (got %)',
      coalesce(public.role_key_of(new.assigned_to_id),'unknown');
  end if;

  -- Hop 2 is the Discovery Manager's (or Admin's) alone. A Sales/KAM user
  -- writing assigned_to_id directly via the API gets rejected here.
  if tg_op = 'UPDATE'
     and new.assigned_to_id is distinct from old.assigned_to_id
     and new.assigned_to_id is not null
     and not (public.is_admin() or public.current_role_key() = 'discovery_manager') then
    raise exception 'only a discovery_manager or admin may set assigned_to_id';
  end if;

  return new;
end $$;
drop trigger if exists trg_requests_assign_targets on public.requests;
create trigger trg_requests_assign_targets before insert or update on public.requests
  for each row execute function public.enforce_assignment_targets();

-- ------------------------------------------------------------
-- B7) Ownership is immutable
--   Reported: "the owner of the enquiry and request is changed" — opening or
--   editing a record was silently reassigning it.
-- ------------------------------------------------------------
create table if not exists public.audit_log (
  id         bigserial primary key,
  actor_id   uuid,
  action     text not null,
  target     text,
  detail     jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
alter table public.audit_log enable row level security;
drop policy if exists audit_select on public.audit_log;
drop policy if exists audit_insert on public.audit_log;
create policy audit_select on public.audit_log for select using (public.is_admin());
create policy audit_insert on public.audit_log for insert with check (public.is_active());

create or replace function public.prevent_owner_overwrite() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.owner_id is distinct from old.owner_id then
    insert into public.audit_log(actor_id, action, target, detail)
    values (auth.uid(), 'owner.overwrite.blocked', tg_table_name || ':' || old.id,
            jsonb_build_object('from', old.owner_id, 'to', new.owner_id));
    raise exception 'owner_id is immutable once set (record %)', old.id;
  end if;
  return new;
end $$;

drop trigger if exists trg_requests_owner_immutable on public.requests;
create trigger trg_requests_owner_immutable before update on public.requests
  for each row execute function public.prevent_owner_overwrite();

drop trigger if exists trg_enquiries_owner_immutable on public.enquiries;
create trigger trg_enquiries_owner_immutable before update on public.enquiries
  for each row execute function public.prevent_owner_overwrite();

-- ------------------------------------------------------------
-- B9) Discovery clock ownership
-- ------------------------------------------------------------
alter table public.requests add column if not exists discovery_started_at timestamptz;
alter table public.requests add column if not exists discovery_started_by uuid references auth.users on delete set null;
alter table public.requests add column if not exists discovery_ended_at   timestamptz;
alter table public.requests add column if not exists discovery_ended_by   uuid references auth.users on delete set null;

-- Only the assigned Discovery Employee, the Discovery Manager, or Admin may
-- move the clock. A Sales user hitting the API directly is rejected.
create or replace function public.enforce_clock_owner() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.discovery_started_at is distinct from old.discovery_started_at
     or new.discovery_ended_at is distinct from old.discovery_ended_at then

    if not (public.is_admin()
            or public.current_role_key() = 'discovery_manager'
            or (new.assigned_to_id is not null and new.assigned_to_id = auth.uid())
            or (new.assignee_id   is not null and new.assignee_id   = auth.uid())) then
      raise exception 'only the assigned discovery employee, the discovery manager or an admin may move the discovery clock';
    end if;

    if new.discovery_started_at is not null
       and new.assigned_to_id is null and new.assignee_id is null then
      raise exception 'assign this request before starting the clock';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_requests_clock_owner on public.requests;
create trigger trg_requests_clock_owner before update on public.requests
  for each row execute function public.enforce_clock_owner();

-- ------------------------------------------------------------
-- B8) Who can raise a request — enforced server side, not just a hidden button
-- ------------------------------------------------------------
create or replace function public.can_raise_request() returns boolean
  language sql stable security definer set search_path = public as $$
    select coalesce((
      select case
        when pr.perms ? 'raise' and jsonb_typeof(pr.perms -> 'raise') <> 'null'
          then (pr.perms ->> 'raise') not in ('0','false')
        else pr.role_key <> 'discovery_employee'
      end
      from public.profiles pr where pr.id = auth.uid() and pr.status = 'active'
    ), false);
  $$;

drop policy if exists req_insert on public.requests;
create policy req_insert on public.requests for insert
  with check (public.is_active() and public.can_raise_request());

-- ------------------------------------------------------------
-- Verify
-- ------------------------------------------------------------
-- Should FAIL (wrong role for hop 1):
--   update public.requests set routed_to_manager_id = '<a sales user id>' where id = '<req>';
-- Should FAIL (wrong role for hop 2):
--   update public.requests set assigned_to_id = '<a sales user id>' where id = '<req>';
-- Should FAIL (ownership immutable):
--   update public.requests set owner_id = '<someone else>' where id = '<req>';


-- ############################################################
-- ## supabase-integrity-migration.sql
-- ## Section C - soft delete, brand uniqueness
-- ############################################################

-- ============================================================
-- DiscoverDesk — Section C: soft delete, brand uniqueness
-- Run AFTER supabase-rbac-migration.sql. Safe to re-run.
-- ============================================================

-- ------------------------------------------------------------
-- C10) Soft delete on requests and enquiries
--   "Not able to delete unnecessary junk enquiries and requests."
--   Deletes are recoverable by Admin; list queries filter deleted_at is null.
-- ------------------------------------------------------------
alter table public.requests  add column if not exists deleted_at timestamptz;
alter table public.requests  add column if not exists deleted_by uuid references auth.users on delete set null;
alter table public.enquiries add column if not exists deleted_at timestamptz;
alter table public.enquiries add column if not exists deleted_by uuid references auth.users on delete set null;

create index if not exists requests_deleted_idx  on public.requests(deleted_at);
create index if not exists enquiries_deleted_idx on public.enquiries(deleted_at);

-- Admin may soft-delete and restore anything; owners may bin their own.
create or replace function public.soft_delete(p_table text, p_ids text[], p_restore boolean default false)
  returns integer
  language plpgsql security definer set search_path = public as $$
declare n integer := 0;
begin
  if not public.is_active() then
    raise exception 'not an active user';
  end if;
  if p_table not in ('requests','enquiries') then
    raise exception 'soft_delete: unsupported table %', p_table;
  end if;

  if p_restore and not public.is_admin() then
    raise exception 'only an admin may restore deleted records';
  end if;

  if p_table = 'requests' then
    update public.requests set
      deleted_at = case when p_restore then null else now() end,
      deleted_by = case when p_restore then null else auth.uid() end
    where id = any(p_ids)
      and (public.is_admin() or owner_id = auth.uid());
    get diagnostics n = row_count;
  else
    update public.enquiries set
      deleted_at = case when p_restore then null else now() end,
      deleted_by = case when p_restore then null else auth.uid() end
    where id = any(p_ids)
      and (public.is_admin() or owner_id = auth.uid());
    get diagnostics n = row_count;
  end if;

  insert into public.audit_log(actor_id, action, target, detail)
  values (auth.uid(),
          case when p_restore then 'record.restore' else 'record.delete' end,
          p_table,
          jsonb_build_object('ids', to_jsonb(p_ids), 'count', n));
  return n;
end $$;

revoke all on function public.soft_delete(text, text[], boolean) from anon;
grant execute on function public.soft_delete(text, text[], boolean) to authenticated;

-- ------------------------------------------------------------
-- C11) Brand uniqueness
--   De-dup FIRST, then add the constraint, or the index creation fails.
--   Keeps the OLDEST row of each duplicate group and repoints references.
-- ------------------------------------------------------------
create table if not exists public.brands (
  id         text primary key,
  name       text not null,
  industry   text,
  status     text,
  data       jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
alter table public.brands enable row level security;
drop policy if exists brands_all on public.brands;
create policy brands_all on public.brands for all
  using (public.is_active()) with check (public.is_active());

-- Report what will be merged before it happens:
--   select lower(btrim(name)) k, count(*), array_agg(id order by created_at)
--   from public.brands group by 1 having count(*) > 1;

do $$
declare
  g record;
  keep text;
  losers text[];
  merged int := 0;
begin
  for g in
    select lower(btrim(name)) as k, array_agg(id order by created_at, id) as ids
    from public.brands group by 1 having count(*) > 1
  loop
    keep := g.ids[1];
    losers := g.ids[2:array_length(g.ids,1)];

    -- Repoint every reference we know about, then drop the duplicates.
    update public.brand_sheets set brand_id = keep where brand_id = any(losers);
    update public.brands set id = id where id = keep;   -- no-op, keeps row live
    delete from public.brands where id = any(losers);

    merged := merged + array_length(losers,1);
  end loop;
  raise notice 'C11: merged % duplicate brand row(s)', merged;
end $$;

create unique index if not exists brands_name_uniq on public.brands (lower(btrim(name)));

-- ------------------------------------------------------------
-- Verify
-- ------------------------------------------------------------
-- Duplicates remaining (should be zero rows):
--   select lower(btrim(name)), count(*) from public.brands group by 1 having count(*)>1;
-- Soft delete round trip:
--   select public.soft_delete('enquiries', array['<id>']);
--   select public.soft_delete('enquiries', array['<id>'], true);   -- restore
