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
