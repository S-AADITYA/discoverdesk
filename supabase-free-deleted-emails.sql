-- ============================================================
-- DiscoverDesk — let deleted users register again (auth cleanup)
-- WHY: account deletion removed only the profile row, never the auth.users
-- login, so re-signup failed with "User already registered".
-- RUN THIS ONCE in the Supabase SQL editor (it runs as the postgres role, which
-- can delete from the auth schema). Safe to re-run.
-- ============================================================

-- 1) Deletion now also removes the login so the email is freed.
create or replace function public.admin_delete_user(p_id uuid) returns boolean
  language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  if exists(select 1 from public.profiles where id = p_id and coalesce(locked,false) = true) then
    raise exception 'the permanent owner cannot be deleted';
  end if;
  update public.requests set assignee_id = null, assigned_to_id = null
    where assignee_id = p_id or assigned_to_id = p_id;
  delete from public.profiles where id = p_id;
  begin
    delete from auth.users where id = p_id;
  exception when others then
    raise notice 'admin_delete_user: auth.users delete skipped: %', sqlerrm;
  end;
  return true;
end $$;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- 2) Admin helper to free a stuck/orphaned email (used by the app + one-offs).
create or replace function public.admin_free_email(p_email text) returns text
  language plpgsql security definer set search_path = public as $$
declare v_count int := 0;
begin
  if not public.is_admin() then raise exception 'not authorized'; end if;
  if exists(select 1 from public.profiles where lower(email) = lower(p_email) and coalesce(locked,false) = true) then
    raise exception 'the permanent owner cannot be freed';
  end if;
  delete from public.profiles where lower(email) = lower(p_email);
  begin
    delete from auth.users where lower(email) = lower(p_email);
    get diagnostics v_count = row_count;
  exception when others then
    return 'profile cleared; auth delete skipped: ' || sqlerrm;
  end;
  return 'freed ' || p_email || ' (auth rows removed: ' || v_count || ')';
end $$;
grant execute on function public.admin_free_email(text) to authenticated;

-- 3) ONE-OFF: free the specific email that is currently stuck.
select public.admin_free_email('anu@myhaulstore.com');

-- (If you get "not authorized" running step 3, run this raw cleanup instead —
--  the SQL editor runs as postgres so it always works:)
-- delete from public.profiles where lower(email) = 'anu@myhaulstore.com';
-- delete from auth.users     where lower(email) = 'anu@myhaulstore.com';
