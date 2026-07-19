-- ============================================================
-- DiscoverDesk — Supabase database setup (real auth + per-user rules)
-- Paste ALL of this into Supabase → SQL Editor → Run.
-- ============================================================

-- 1) PROFILES: one row per team member, linked to the secure auth system.
--    Passwords are handled & encrypted by Supabase Auth — never stored here.
create table if not exists public.profiles (
  id          uuid primary key references auth.users on delete cascade,
  name        text default '',
  email       text,
  role        text default 'sales',      -- sales | kam | discovery | admin
  status      text default 'pending',    -- pending | active | disabled
  perms       jsonb,
  email_prefs jsonb default '{"assigned":1,"submitted":1,"decision":1,"account":1}'::jsonb,
  locked      boolean default false,     -- permanent admin
  created_at  timestamptz default now()
);
alter table public.profiles enable row level security;

-- 2) Helper checks (run with elevated rights to avoid policy recursion)
create or replace function public.is_active() returns boolean
  language sql security definer stable as $$
    select exists(select 1 from public.profiles where id = auth.uid() and status = 'active');
  $$;
create or replace function public.is_admin() returns boolean
  language sql security definer stable as $$
    select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin' and status = 'active');
  $$;

-- 3) Who can see / change profiles
drop policy if exists p_select    on public.profiles;
drop policy if exists p_upd_self  on public.profiles;
drop policy if exists p_upd_admin on public.profiles;
create policy p_select    on public.profiles for select using (auth.uid() is not null);
create policy p_upd_self  on public.profiles for update using (auth.uid() = id)   with check (auth.uid() = id);
create policy p_upd_admin on public.profiles for update using (public.is_admin()) with check (public.is_admin());

-- 4) Auto-create a profile when someone signs up.
--    The VERY FIRST person to sign up becomes the permanent ADMIN, already active.
create or replace function public.handle_new_user() returns trigger
  language plpgsql security definer as $$
declare cnt int;
begin
  select count(*) into cnt from public.profiles;
  insert into public.profiles (id, name, email, role, status, locked)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'name', ''),
    new.email,
    case when cnt = 0 then 'admin' else coalesce(new.raw_user_meta_data->>'role', 'sales') end,
    case when cnt = 0 then 'active' else 'pending' end,
    cnt = 0
  );
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- 5) KV: holds all the working data (brands, requests, sheets, rounds, etc.)
--    Only APPROVED (active) team members can read or write it.
create table if not exists public.kv (
  key        text primary key,
  value      jsonb,
  updated_at timestamptz default now()
);
alter table public.kv enable row level security;
drop policy if exists kv_all on public.kv;
create policy kv_all on public.kv for all using (public.is_active()) with check (public.is_active());

-- 6) Live updates for everyone.
--    If this line errors saying the table is already added, ignore it.
alter publication supabase_realtime add table public.kv;

-- Done. Back to DEPLOY.md step 4.
