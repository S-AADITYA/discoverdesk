-- ============================================================
-- DiscoverDesk — People fixes (run once in Supabase → SQL editor)
--   1) Everyone signed in can READ all profiles (names/roles). This is what
--      lets Discovery see WHO raised a request, and makes the people list
--      complete for assignment, comments, oversight, etc. Work visibility
--      (requests/enquiries) stays enforced by their own policies.
--   2) Admins can DELETE a profile — so deleting an employee actually sticks
--      instead of reappearing on refresh.
-- Safe to re-run.
-- ============================================================

-- 1) Read all profiles when authenticated
drop policy if exists p_select on public.profiles;
create policy p_select on public.profiles for select
  using ( auth.uid() is not null );

-- 2) Admins may delete profiles
drop policy if exists p_delete_admin on public.profiles;
create policy p_delete_admin on public.profiles for delete
  using ( public.is_admin() );
