-- ============================================================
-- DiscoverDesk — Stage 3: real `roster` table + DB-enforced contact hiding
-- Paste ALL of this into Supabase → SQL Editor → Run.
-- Run AFTER Stage 1 (requests) and Stage 2 (enquiries). Safe to re-run.
--
-- WHAT THIS DOES
--  1. Creates a real `roster` table, splitting each creator into:
--       data    jsonb — everything except email/phone
--       contact jsonb — {email, phone}
--  2. LOCKS the base table: `authenticated` gets NO direct access to it.
--     Reads go through the view `roster_v`, which returns `contact` only
--     when the caller actually holds the 'contacts' permission. A user
--     without it cannot see phone/email even by calling the REST API
--     directly — the masking is in the database, not the UI.
--  3. Writes go through the `roster_sync` RPC, which REFUSES to overwrite
--     the contact fields for callers who can't see them. Without this, a
--     no-contacts user loading masked data and hitting save would blank
--     out everyone's phone/email.
--  4. Copies the existing roster out of the `kv` blob.
--
-- WHY A VIEW + RPC AND NOT PLAIN RLS
--  RLS is row-level. "Hide two columns from some users" is column-level,
--  which RLS cannot express — hence the locked table + masking view.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Permission helpers — mirror of ROLE_DEFAULTS / can() in index.html.
--    Keep these in sync if you change role defaults in the app.
-- ------------------------------------------------------------
create or replace function public.role_defaults(r text) returns jsonb
  language sql immutable as $$
    select case r
      when 'sales'     then '{"raise":1,"enquiries":1,"review":1,"influencers":0,"clientview":1,"brandcost":1,"export":1,"poolfill":1}'::jsonb
      when 'kam'       then '{"raise":1,"enquiries":1,"review":1,"influencers":1,"roster":1,"clientview":1,"contacts":1,"brandcost":1,"export":1,"poolfill":1}'::jsonb
      when 'discovery' then '{"discover":1,"influencers":1,"roster":1,"export":1,"poolfill":1}'::jsonb
      when 'manager'   then '{"raise":1,"enquiries":1,"assign":1,"review":1,"discover":1,"influencers":1,"roster":1,"clientview":1,"contacts":1,"brandcost":1,"export":1,"poolfill":1}'::jsonb
      when 'admin'     then '{"raise":1,"enquiries":1,"assign":1,"discover":1,"review":1,"influencers":1,"roster":1,"bridge":1,"brandcost":1,"clientview":1,"contacts":1,"export":1,"integrations":1,"admin":1,"poolfill":1}'::jsonb
      else '{}'::jsonb end
  $$;

-- Same precedence as can() in the app: an explicit per-user override wins,
-- otherwise fall back to the role default. Only active users hold anything.
create or replace function public.has_perm(p text) returns boolean
  language sql stable security definer set search_path = public as $$
    select coalesce((
      select case
        when pr.perms ? p and jsonb_typeof(pr.perms -> p) <> 'null'
          then (pr.perms ->> p) not in ('0','false')
        else coalesce((public.role_defaults(pr.role) ->> p) not in ('0','false'), false)
      end
      from public.profiles pr
      where pr.id = auth.uid() and pr.status = 'active'
    ), false);
  $$;

create or replace function public.safe_epoch(t text) returns timestamptz
  language sql immutable as $$
    select case when t ~ '^[0-9]{1,15}$'
                then to_timestamp(t::bigint / 1000.0)
                else now() end
  $$;

-- ------------------------------------------------------------
-- 2) The roster table (base table — deliberately NOT reachable by clients)
-- ------------------------------------------------------------
create table if not exists public.roster (
  id         text primary key,
  data       jsonb not null default '{}'::jsonb,   -- everything except email/phone
  contact    jsonb not null default '{}'::jsonb,   -- {email, phone} — masked on read
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
alter table public.roster enable row level security;

create or replace function public.touch_updated_at() returns trigger
  language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_roster_touch on public.roster;
create trigger trg_roster_touch before update on public.roster
  for each row execute function public.touch_updated_at();

-- No policies are created for `roster`, and RLS is on: with RLS enabled and
-- zero policies, every direct client query returns nothing. Belt and braces,
-- we also drop the table-level grants. Only SECURITY DEFINER code (the view
-- and the sync RPC, both owned by postgres) can reach the real rows.
revoke all on public.roster from anon, authenticated;

-- ------------------------------------------------------------
-- 3) The masking view — this is what the app reads
-- ------------------------------------------------------------
-- NOTE: this view intentionally runs with the *owner's* rights (the Postgres
-- default, security_invoker = false) so it can read the locked base table.
-- Supabase's linter flags that as "security definer view" — here it is the
-- whole point. The view does its own authorization in the WHERE clause.
drop view if exists public.roster_v;
create view public.roster_v as
  select
    r.id,
    r.data,
    case when public.has_perm('contacts') then r.contact else '{}'::jsonb end as contact,
    public.has_perm('contacts') as contact_visible,
    r.created_at,
    r.updated_at
  from public.roster r
  where public.is_active();

grant select on public.roster_v to authenticated;

-- ------------------------------------------------------------
-- 4) Writes — one RPC that upserts a batch and deletes removed ids.
--    Contact fields are preserved (never blanked) for callers who can't
--    see them.
-- ------------------------------------------------------------
create or replace function public.roster_sync(p_rows jsonb, p_removed text[] default '{}')
  returns integer
  language plpgsql security definer set search_path = public as $$
declare
  n integer := 0;
  can_contacts boolean := public.has_perm('contacts');
begin
  if not public.is_active() then
    raise exception 'roster_sync: not an active user';
  end if;

  -- Deliberately NOT gated on the 'roster' permission. The roster blob is
  -- written as a side effect of flows that non-roster users legitimately
  -- run — updateRevCount() in the review/rounds flow and creatorNoteSave()
  -- both call save('roster'), and a sales user can reach both. Gating writes
  -- here would break reviews for them.
  --
  -- That costs nothing in confidentiality: the contact fields are the
  -- sensitive part, and the ON CONFLICT clause below refuses to let a
  -- caller who cannot READ them overwrite them. Everything else in the
  -- roster is already readable by every active user.

  if p_rows is not null and jsonb_typeof(p_rows) = 'array' then
    -- distinct on: ON CONFLICT cannot touch the same row twice in one
    -- statement, so a duplicate id inside the batch would abort the save.
    insert into public.roster (id, data, contact)
    select distinct on (x->>'id')
      x->>'id',
      coalesce(x->'data', '{}'::jsonb),
      coalesce(x->'contact', '{}'::jsonb)
    from jsonb_array_elements(p_rows) as x
    where x->>'id' is not null
    on conflict (id) do update set
      data = excluded.data,
      -- The important line: a caller who cannot READ contacts cannot
      -- OVERWRITE them either. Their masked payload is ignored.
      contact = case when can_contacts then excluded.contact
                     else roster.contact end;
    get diagnostics n = row_count;
  end if;

  if p_removed is not null and array_length(p_removed, 1) > 0 then
    delete from public.roster where id = any(p_removed);
  end if;

  -- Nudge the kv table so other browsers' realtime subscription fires and
  -- they reload. The roster table itself is deliberately kept out of the
  -- realtime publication — realtime payloads bypass the masking view and
  -- would ship raw contact rows to every subscriber.
  insert into public.kv (key, value) values ('dd:rosterver', to_jsonb(extract(epoch from now())))
  on conflict (key) do update set value = excluded.value;

  return n;
end $$;

revoke all on function public.roster_sync(jsonb, text[]) from anon;
grant execute on function public.roster_sync(jsonb, text[]) to authenticated;

-- ------------------------------------------------------------
-- 5) ONE-TIME MIGRATION — split the kv roster blob into data + contact.
--    Safe to run more than once.
-- ------------------------------------------------------------
insert into public.roster (id, data, contact, created_at)
select distinct on (r->>'id')
  r->>'id',
  (r - 'email' - 'phone') as data,
  jsonb_strip_nulls(jsonb_build_object(
    'email', r->>'email',
    'phone', r->>'phone'
  )) as contact,
  public.safe_epoch(r->>'addedAt') as created_at
from public.kv, jsonb_array_elements(coalesce(value,'[]'::jsonb)) as r
where key = 'dd:roster' and r->>'id' is not null
on conflict (id) do update set
  data    = excluded.data,
  contact = excluded.contact;

-- ------------------------------------------------------------
-- 6) Verify the masking actually works
-- ------------------------------------------------------------
-- As an admin/kam/manager (has 'contacts'):
--   select id, contact, contact_visible from public.roster_v limit 5;
--   -> contact populated, contact_visible = true
-- As a sales/discovery user (no 'contacts'):
--   -> contact = {}, contact_visible = false
-- And the base table is unreachable either way:
--   select * from public.roster;   -> permission denied
--
-- The old 'dd:roster' key in kv is left untouched as a backup. Once you're
-- happy, clear it with:
--   update public.kv set value = '[]'::jsonb where key = 'dd:roster';
