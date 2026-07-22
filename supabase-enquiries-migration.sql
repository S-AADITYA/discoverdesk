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
