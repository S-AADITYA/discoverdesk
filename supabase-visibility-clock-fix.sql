-- ============================================================
-- DiscoverDesk — Visibility + Clock fix
-- Run this ONCE in Supabase → SQL editor (paste → Run). Safe to re-run.
--
-- Fixes three things that the app cannot fix on its own because they are
-- enforced by the DATABASE, not the browser:
--   1) Sales/KAM MANAGERS could only see ONE team's requests. Now they see
--      their whole DEPARTMENT (the app then narrows to the exact teams you
--      tick under People & Access → Manager oversight).
--   2) Auto-start of the discovery clock, done by the Sales/KAM person when
--      they route a request to a Discovery Manager, was rejected by a trigger.
--      Now the request owner (and the manager it is routed to) may start it.
--   3) Uploaded round sheets by Discovery are saved via UPDATE (the app change),
--      which this file's policies already permit.
-- ============================================================

-- ---- helpers: department of a user / of the caller ----
create or replace function public.owner_dept(oid uuid)
  returns text language sql stable security definer set search_path = public as $$
  select case
    when p.role_key like 'sales%'     then 'sales'
    when p.role_key like 'kam%'       then 'kam'
    when p.role_key like 'discovery%' then 'discovery'
    else 'admin' end
  from public.profiles p where p.id = oid;
$$;

create or replace function public.my_dept()
  returns text language sql stable security definer set search_path = public as $$
  select case
    when public.current_role_key() like 'sales%'     then 'sales'
    when public.current_role_key() like 'kam%'       then 'kam'
    when public.current_role_key() like 'discovery%' then 'discovery'
    else 'admin' end;
$$;

-- ------------------------------------------------------------
-- 1) REQUESTS — managers see their whole department
-- ------------------------------------------------------------
drop policy if exists req_select on public.requests;
create policy req_select on public.requests for select using (
  public.is_admin()
  or public.current_role_key() = 'discovery_manager'                 -- all discovery work
  or (public.current_role_key() = 'discovery_employee'
      and assignee_id = auth.uid())                                  -- only assigned
  or (public.current_role_key() in ('sales_employee','kam_employee')
      and owner_id = auth.uid())                                     -- own only
  or (public.current_role_key() in ('sales_manager','kam_manager')
      and public.owner_dept(owner_id) = public.my_dept())            -- whole department
);

-- ------------------------------------------------------------
-- 2) ENQUIRIES — managers see their whole department
-- ------------------------------------------------------------
drop policy if exists enq_select on public.enquiries;
create policy enq_select on public.enquiries for select using (
  public.is_admin()
  or (public.current_role_key() in ('sales_employee','kam_employee')
      and owner_id = auth.uid())
  or (public.current_role_key() in ('sales_manager','kam_manager')
      and public.owner_dept(owner_id) = public.my_dept())
  or (public.current_role_key() = 'discovery_manager'
      and (data ? 'convertedRequestId' or coalesce(data->>'status','') = 'won'))
);

-- ------------------------------------------------------------
-- 3) REQUESTS — allow the owner / routed manager to UPDATE
--    (needed so the Sales/KAM owner can auto-start the clock)
-- ------------------------------------------------------------
drop policy if exists req_update on public.requests;
create policy req_update on public.requests for update using (
  public.is_admin()
  or public.current_role_key() = 'discovery_manager'
  or owner_id = auth.uid()
  or assignee_id = auth.uid()
  or routed_to_manager_id = auth.uid()
) with check (
  public.is_admin()
  or public.current_role_key() = 'discovery_manager'
  or owner_id = auth.uid()
  or assignee_id = auth.uid()
  or routed_to_manager_id = auth.uid()
);

-- ------------------------------------------------------------
-- 4) CLOCK trigger — let the owner / routed manager start it
-- ------------------------------------------------------------
create or replace function public.enforce_clock_owner() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.discovery_started_at is distinct from old.discovery_started_at
     or new.discovery_ended_at is distinct from old.discovery_ended_at then

    if not (public.is_admin()
            or public.current_role_key() = 'discovery_manager'
            or (new.assigned_to_id is not null and new.assigned_to_id = auth.uid())
            or (new.assignee_id     is not null and new.assignee_id     = auth.uid())
            or (new.owner_id        is not null and new.owner_id        = auth.uid())   -- Sales/KAM owner (auto-start)
            or (new.routed_to_manager_id is not null and new.routed_to_manager_id = auth.uid())) then
      raise exception 'only the owner, the assigned discovery person, the discovery manager or an admin may move the discovery clock';
    end if;

    -- must be at least routed or assigned before the clock can start
    if new.discovery_started_at is not null
       and new.assigned_to_id is null and new.assignee_id is null
       and new.routed_to_manager_id is null then
      raise exception 'assign or route this request before starting the clock';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_requests_clock_owner on public.requests;
create trigger trg_requests_clock_owner before update on public.requests
  for each row execute function public.enforce_clock_owner();

-- Done. Sign out and back in once so the new policies take effect.
