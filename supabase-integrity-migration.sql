-- ============================================================
-- DiscoverDesk — Section C: soft delete, brand uniqueness
-- Run AFTER supabase-rbac-migration.sql. Safe to re-run.
-- ============================================================

-- ------------------------------------------------------------
-- C10) Soft delete on requests and enquiries
--   "Not able to delete unnecessary junk enquiries and requests."
--   Deletes are recoverable by Admin; list queries filter deleted_at is null.
-- ------------------------------------------------------------
alter table public.requests  add column if not exists deleted_at timestamptz;
alter table public.requests  add column if not exists deleted_by uuid references auth.users on delete set null;
alter table public.enquiries add column if not exists deleted_at timestamptz;
alter table public.enquiries add column if not exists deleted_by uuid references auth.users on delete set null;

create index if not exists requests_deleted_idx  on public.requests(deleted_at);
create index if not exists enquiries_deleted_idx on public.enquiries(deleted_at);

-- Admin may soft-delete and restore anything; owners may bin their own.
create or replace function public.soft_delete(p_table text, p_ids text[], p_restore boolean default false)
  returns integer
  language plpgsql security definer set search_path = public as $$
declare n integer := 0;
begin
  if not public.is_active() then
    raise exception 'not an active user';
  end if;
  if p_table not in ('requests','enquiries') then
    raise exception 'soft_delete: unsupported table %', p_table;
  end if;

  if p_restore and not public.is_admin() then
    raise exception 'only an admin may restore deleted records';
  end if;

  if p_table = 'requests' then
    update public.requests set
      deleted_at = case when p_restore then null else now() end,
      deleted_by = case when p_restore then null else auth.uid() end
    where id = any(p_ids)
      and (public.is_admin() or owner_id = auth.uid());
    get diagnostics n = row_count;
  else
    update public.enquiries set
      deleted_at = case when p_restore then null else now() end,
      deleted_by = case when p_restore then null else auth.uid() end
    where id = any(p_ids)
      and (public.is_admin() or owner_id = auth.uid());
    get diagnostics n = row_count;
  end if;

  insert into public.audit_log(actor_id, action, target, detail)
  values (auth.uid(),
          case when p_restore then 'record.restore' else 'record.delete' end,
          p_table,
          jsonb_build_object('ids', to_jsonb(p_ids), 'count', n));
  return n;
end $$;

revoke all on function public.soft_delete(text, text[], boolean) from anon;
grant execute on function public.soft_delete(text, text[], boolean) to authenticated;

-- ------------------------------------------------------------
-- C11) Brand uniqueness
--   De-dup FIRST, then add the constraint, or the index creation fails.
--   Keeps the OLDEST row of each duplicate group and repoints references.
-- ------------------------------------------------------------
create table if not exists public.brands (
  id         text primary key,
  name       text not null,
  industry   text,
  status     text,
  data       jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
alter table public.brands enable row level security;
drop policy if exists brands_all on public.brands;
create policy brands_all on public.brands for all
  using (public.is_active()) with check (public.is_active());

-- Report what will be merged before it happens:
--   select lower(btrim(name)) k, count(*), array_agg(id order by created_at)
--   from public.brands group by 1 having count(*) > 1;

do $$
declare
  g record;
  keep text;
  losers text[];
  merged int := 0;
begin
  for g in
    select lower(btrim(name)) as k, array_agg(id order by created_at, id) as ids
    from public.brands group by 1 having count(*) > 1
  loop
    keep := g.ids[1];
    losers := g.ids[2:array_length(g.ids,1)];

    -- Repoint every reference we know about, then drop the duplicates.
    update public.brand_sheets set brand_id = keep where brand_id = any(losers);
    update public.brands set id = id where id = keep;   -- no-op, keeps row live
    delete from public.brands where id = any(losers);

    merged := merged + array_length(losers,1);
  end loop;
  raise notice 'C11: merged % duplicate brand row(s)', merged;
end $$;

create unique index if not exists brands_name_uniq on public.brands (lower(btrim(name)));

-- ------------------------------------------------------------
-- Verify
-- ------------------------------------------------------------
-- Duplicates remaining (should be zero rows):
--   select lower(btrim(name)), count(*) from public.brands group by 1 having count(*)>1;
-- Soft delete round trip:
--   select public.soft_delete('enquiries', array['<id>']);
--   select public.soft_delete('enquiries', array['<id>'], true);   -- restore
