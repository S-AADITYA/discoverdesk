-- ============================================================
-- DiscoverDesk — Stage 5: real `brand_sheets` table
-- Paste ALL of this into Supabase → SQL Editor → Run. Safe to re-run.
--
-- WHY THIS EXISTS (this is a bug fix, not just isolation work)
--  db.infl in index.html holds BRAND SHEETS — per-brand/per-campaign working
--  lists of creators, shaped {id, brandId, campaignId, handle, status, ...}.
--  A previous change pointed its LOAD at the `influencers` master creator
--  table, which has no brand_id/campaign_id columns and a totally different
--  shape. The WRITE was never repointed, so save('infl') kept writing to the
--  kv key 'dd:influencers' — a key cloud mode no longer reads.
--
--  Net effect in production: brand sheets load as the wrong data, and every
--  edit, bulk status change, import and delete is lost on the next reload.
--
--  This table gives brand sheets their own home, with the shape they
--  actually have. The `influencers` master table is left alone — it is a
--  separate concern (the global creator database).
--
-- VISIBILITY
--  Deliberately readable by every active user, which is exactly what the kv
--  blob did today. This migration is a data-loss fix and intentionally does
--  NOT change who can see what — narrowing brand-sheet visibility is a
--  separate decision, since discovery/sales/kam collaborate on these lists
--  across teams. team_id is recorded now so you can tighten it later.
-- ============================================================

create table if not exists public.brand_sheets (
  id          text primary key,
  team_id     text,
  brand_id    text,
  campaign_id text,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);
alter table public.brand_sheets enable row level security;

create or replace function public.touch_updated_at() returns trigger
  language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists trg_brand_sheets_touch on public.brand_sheets;
create trigger trg_brand_sheets_touch before update on public.brand_sheets
  for each row execute function public.touch_updated_at();

create index if not exists brand_sheets_brand_idx on public.brand_sheets(brand_id);
create index if not exists brand_sheets_camp_idx  on public.brand_sheets(campaign_id);

-- RLS — same reach the kv blob had: any active user.
drop policy if exists bs_select on public.brand_sheets;
drop policy if exists bs_insert on public.brand_sheets;
drop policy if exists bs_update on public.brand_sheets;
drop policy if exists bs_delete on public.brand_sheets;

create policy bs_select on public.brand_sheets for select using (public.is_active());
create policy bs_insert on public.brand_sheets for insert with check (public.is_active());
create policy bs_update on public.brand_sheets for update using (public.is_active())
  with check (public.is_active());
-- delInfl / bulkDelInfl are used by discovery and kam users, not just admins.
create policy bs_delete on public.brand_sheets for delete using (public.is_active());

-- Realtime
do $$ begin
  alter publication supabase_realtime add table public.brand_sheets;
exception when duplicate_object then null;
end $$;

-- ONE-TIME MIGRATION — recover the brand sheets still sitting in kv.
-- This is the data your team's recent edits were being written to.
insert into public.brand_sheets (id, team_id, brand_id, campaign_id, data, created_at)
select distinct on (i->>'id')
  i->>'id',
  'default',
  i->>'brandId',
  i->>'campaignId',
  i,
  case when (i->>'addedAt') ~ '^[0-9]{1,15}$'
       then to_timestamp((i->>'addedAt')::bigint/1000.0)
       else now() end
from public.kv, jsonb_array_elements(coalesce(value,'[]'::jsonb)) as i
where key = 'dd:influencers' and i->>'id' is not null
on conflict (id) do update set
  brand_id    = excluded.brand_id,
  campaign_id = excluded.campaign_id,
  data        = excluded.data;

-- Check what came back:
--   select count(*) from public.brand_sheets;
