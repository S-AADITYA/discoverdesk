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
create policy p_select on public.profiles for select using (
  public.is_admin()
  or id = auth.uid()                                   -- always see yourself
  or (public.current_role_key() = 'discovery_manager'  -- whole Discovery dept
      and department = 'discovery')
  or (team_uid is not null and team_uid = public.current_team_id())
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
