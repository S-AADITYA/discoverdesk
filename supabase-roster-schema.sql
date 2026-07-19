-- ============================================================
-- DiscoverDesk — Roster scale-pack schema (Supabase / Postgres)
-- Designed for tens of millions of influencer rows with:
--   • normalized tables + indexes for fast filtered search
--   • an append-only history table (never overwrite past data)
--   • related tables for content, collabs, docs, notes, comms
--   • JSONB for audience demographics, pricing and social handles
-- Run this in Supabase → SQL editor (after the base supabase-schema.sql).
-- ============================================================

create extension if not exists pg_trgm;      -- fast text search on handle/name

-- ---------- master influencer table ----------
create table if not exists influencers (
  id            uuid primary key default gen_random_uuid(),
  platform      text not null default 'instagram',   -- instagram | youtube | tiktok | x
  handle        text not null,
  name          text,
  bio           text,
  profile_url   text,
  avatar_url    text,
  followers     bigint default 0,
  engagement    numeric(6,3) default 0,              -- percent, e.g. 4.250
  avg_likes     bigint default 0,
  avg_comments  bigint default 0,
  avg_views     bigint default 0,
  category      text,
  niches        text[] default '{}',
  country       text,
  city          text,
  languages     text[] default '{}',
  gender        text,
  audience      jsonb default '{}',   -- {age:{"18-24":0.3,...}, gender:{f:.6,m:.4}, geo:{"IN":.7}, languages:{"en":.8}}
  pricing       jsonb default '{}',   -- {reel:120000, story:40000, post:80000, ...}
  handles       jsonb default '{}',   -- {instagram:"...", youtube:"...", website:"..."}
  tags          text[] default '{}',  -- custom internal tags
  availability  text default 'unknown',
  brand_cost    numeric default 0,    -- what you charge the client
  internal_cost numeric default 0,    -- what the creator costs you
  source        text default 'manual',-- manual | sheet | provider
  last_synced   timestamptz,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now(),
  unique (platform, handle)
);

-- ---------- indexes for filtered search on hundreds of parameters ----------
create index if not exists idx_inf_followers   on influencers (followers desc);
create index if not exists idx_inf_engagement  on influencers (engagement desc);
create index if not exists idx_inf_category     on influencers (category);
create index if not exists idx_inf_country      on influencers (country);
create index if not exists idx_inf_city         on influencers (city);
create index if not exists idx_inf_availability on influencers (availability);
create index if not exists idx_inf_lastsync     on influencers (last_synced);
create index if not exists idx_inf_niches       on influencers using gin (niches);
create index if not exists idx_inf_languages    on influencers using gin (languages);
create index if not exists idx_inf_tags         on influencers using gin (tags);
create index if not exists idx_inf_audience     on influencers using gin (audience jsonb_path_ops);
create index if not exists idx_inf_handle_trgm  on influencers using gin (handle gin_trgm_ops);
create index if not exists idx_inf_name_trgm    on influencers using gin (name gin_trgm_ops);

-- ---------- append-only metrics history (track growth over time) ----------
-- Never overwrite: every refresh inserts a new snapshot row.
create table if not exists influencer_history (
  id           bigserial primary key,
  influencer_id uuid references influencers(id) on delete cascade,
  captured_at  timestamptz default now(),
  followers    bigint,
  engagement   numeric(6,3),
  avg_likes    bigint,
  avg_comments bigint,
  avg_views    bigint
);
create index if not exists idx_hist_inf_time on influencer_history (influencer_id, captured_at desc);
-- For very large volumes, partition influencer_history BY RANGE (captured_at) monthly.

-- ---------- last posts / content ----------
create table if not exists influencer_content (
  id           bigserial primary key,
  influencer_id uuid references influencers(id) on delete cascade,
  permalink    text,
  media_type   text,
  posted_at    timestamptz,
  likes        bigint,
  comments     bigint,
  views        bigint,
  caption      text
);
create index if not exists idx_content_inf on influencer_content (influencer_id, posted_at desc);

-- ---------- brand collaborations / campaign history ----------
create table if not exists influencer_collabs (
  id           bigserial primary key,
  influencer_id uuid references influencers(id) on delete cascade,
  brand        text,
  campaign     text,
  status       text,           -- selected | rejected | delivered
  round        int,
  cost         numeric,
  happened_at  timestamptz
);
create index if not exists idx_collab_inf on influencer_collabs (influencer_id);

-- ---------- documents, notes, communication history ----------
create table if not exists influencer_docs (
  id bigserial primary key,
  influencer_id uuid references influencers(id) on delete cascade,
  name text, url text, created_at timestamptz default now());

create table if not exists influencer_notes (
  id bigserial primary key,
  influencer_id uuid references influencers(id) on delete cascade,
  author text, body text, created_at timestamptz default now());

create table if not exists influencer_comms (
  id bigserial primary key,
  influencer_id uuid references influencers(id) on delete cascade,
  channel text, direction text, summary text, at timestamptz default now());

-- ---------- P&L view (Roster Bridge) ----------
create or replace view roster_pnl as
select id, handle, category, brand_cost, internal_cost,
       (brand_cost - internal_cost) as margin,
       case when brand_cost > 0 then round((brand_cost - internal_cost)/brand_cost*100,1) else 0 end as margin_pct
from influencers;

-- ---------- keep updated_at fresh ----------
create or replace function touch_updated_at() returns trigger as $$
begin new.updated_at = now(); return new; end; $$ language plpgsql;
drop trigger if exists trg_inf_touch on influencers;
create trigger trg_inf_touch before update on influencers
  for each row execute function touch_updated_at();

-- ---------- Row Level Security ----------
alter table influencers        enable row level security;
alter table influencer_history enable row level security;
alter table influencer_content enable row level security;
alter table influencer_collabs enable row level security;
alter table influencer_docs    enable row level security;
alter table influencer_notes   enable row level security;
alter table influencer_comms   enable row level security;

-- Authenticated users can read the roster; writes go through the service-role
-- functions (sheets-sync / provider-refresh) which bypass RLS.
-- Internal cost / margin visibility is enforced in the app by the 'bridge' permission.
do $$ begin
  create policy inf_read on influencers for select to authenticated using (true);
exception when duplicate_object then null; end $$;
do $$ begin
  create policy hist_read on influencer_history for select to authenticated using (true);
exception when duplicate_object then null; end $$;

-- Per-user module visibility (admin decides who sees which modules)
alter table if exists profiles add column if not exists mods jsonb;
