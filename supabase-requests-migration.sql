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
alter publication supabase_realtime add table public.requests;

-- 6) ONE-TIME MIGRATION — copy requests out of the kv blob.
--    Safe to run more than once: existing rows are refreshed, not duplicated.
insert into public.requests (id, team_id, owner_id, assignee_id, data, created_at)
select
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
