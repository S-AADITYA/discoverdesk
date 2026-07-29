-- ============================================================
-- DiscoverDesk — reliable account deletion + admin recognition
-- Run once (already applied). Safe to re-run.
-- ============================================================

-- is_admin() also trusts an app-granted admin permission (perms.admin), not
-- just role='admin', so every admin action the app allows is allowed by the DB.
create or replace function public.is_admin() returns boolean
  language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.profiles
    where id = auth.uid() and status = 'active'
      and (role_key = 'admin' or role = 'admin'
           or coalesce(perms->>'admin','') in ('1','true','t','yes'))
  );
$$;

-- One explicit, race-proof deletion path the client calls directly.
create or replace function public.admin_delete_user(p_id uuid) returns boolean
  language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized';
  end if;
  if exists(select 1 from public.profiles where id = p_id and coalesce(locked,false) = true) then
    raise exception 'the permanent owner cannot be deleted';
  end if;
  -- hand any live work back to the pool, then remove the account
  update public.requests set assignee_id = null, assigned_to_id = null
    where assignee_id = p_id or assigned_to_id = p_id;
  delete from public.profiles where id = p_id;
  return true;
end $$;

grant execute on function public.admin_delete_user(uuid) to authenticated;
