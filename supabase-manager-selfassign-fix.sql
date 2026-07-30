-- ============================================================
-- DiscoverDesk — allow a Discovery Manager to take a request themselves
-- The assignment trigger only permitted assigned_to_id to be a
-- discovery_employee, so a manager self-assigning was rejected and reverted.
-- Now a discovery_manager may also be the assignee. Safe to re-run.
-- ============================================================
create or replace function public.enforce_assignment_targets() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.routed_to_manager_id is not null
     and public.role_key_of(new.routed_to_manager_id) is distinct from 'discovery_manager' then
    raise exception 'routed_to_manager_id must reference a discovery_manager (got %)',
      coalesce(public.role_key_of(new.routed_to_manager_id),'unknown');
  end if;

  -- Discovery EMPLOYEE or (self-assigning) Discovery MANAGER may be the worker.
  if new.assigned_to_id is not null
     and public.role_key_of(new.assigned_to_id) not in ('discovery_employee','discovery_manager') then
    raise exception 'assigned_to_id must reference a discovery employee or manager (got %)',
      coalesce(public.role_key_of(new.assigned_to_id),'unknown');
  end if;

  -- Hop 2 is still the Discovery Manager's (or Admin's) alone.
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
