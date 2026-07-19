-- ============================================================
-- DiscoverDesk — admin fix
-- Run this in Supabase → SQL editor if you can't approve users or
-- change permissions on the live site. Safe to run more than once.
-- ============================================================

-- 1) Make sure the security helpers exist and run with elevated rights
create or replace function public.is_active() returns boolean
  language sql security definer stable as $$
    select exists(select 1 from public.profiles where id = auth.uid() and status = 'active');
  $$;
create or replace function public.is_admin() returns boolean
  language sql security definer stable as $$
    select exists(select 1 from public.profiles where id = auth.uid() and role = 'admin' and status = 'active');
  $$;

-- 2) Re-affirm the profile policies (admins may update ANY profile)
alter table public.profiles enable row level security;
drop policy if exists p_select    on public.profiles;
drop policy if exists p_upd_self  on public.profiles;
drop policy if exists p_upd_admin on public.profiles;
create policy p_select    on public.profiles for select using (auth.uid() is not null);
create policy p_upd_self  on public.profiles for update using (auth.uid() = id)   with check (auth.uid() = id);
create policy p_upd_admin on public.profiles for update using (public.is_admin()) with check (public.is_admin());

-- 3) >>> PROMOTE YOUR ACCOUNT TO ADMIN <<<
--    Replace the email with the one you signed in with.
update public.profiles
set role = 'admin', status = 'active', locked = true
where email = 'YOUR_EMAIL_HERE';

-- 4) Check it worked — this should show your row as admin/active
-- select email, role, status, locked from public.profiles order by created_at;

-- After running: sign out and back in on the live site.
-- Also confirm Auth → Providers → Email → "Confirm email" is OFF,
-- otherwise new signups stay stuck before they reach 'pending'.
