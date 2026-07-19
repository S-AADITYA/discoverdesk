-- DiscoverDesk Phase-1 schema: multi-tenant, RLS, indexed for scale.
-- Every row carries tenant_id (the brand/org). This is how 1M brands stay isolated
-- in ONE database without 1M databases.

create extension if not exists pg_trgm;      -- fast fuzzy search
-- create extension if not exists vector;    -- enable for semantic search (later phase)

create table tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz default now()
);

create table profiles (               -- app users
  id uuid primary key references auth.users on delete cascade,
  tenant_id uuid references tenants not null,
  name text, email text, role text default 'sales',
  is_primary boolean default false,   -- the protected owner account
  perms jsonb, status text default 'active',
  created_at timestamptz default now()
);

create table creators (               -- the roster; built to hold millions
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references tenants not null,
  handle text not null,
  name text, platform text, profile_url text,
  followers bigint default 0,
  engagement numeric, category text, city text, country text,
  brand_cost bigint, internal_cost bigint, price_type text,
  audience jsonb, scores jsonb, custom jsonb,
  created_by uuid references profiles,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- Indexes that make 10M rows return 50 in ~20ms:
create index creators_tenant_idx     on creators (tenant_id);
create index creators_followers_idx  on creators (tenant_id, followers desc);
create index creators_category_idx   on creators (tenant_id, category);
create index creators_handle_trgm    on creators using gin (handle gin_trgm_ops);
create index creators_name_trgm      on creators using gin (name gin_trgm_ops);
create unique index creators_uniq    on creators (tenant_id, lower(handle));

-- ROW-LEVEL SECURITY: a user only ever sees their own tenant's rows.
alter table creators enable row level security;
alter table profiles enable row level security;

create policy creators_isolation on creators
  using (tenant_id = (select tenant_id from profiles where id = auth.uid()));

create policy profiles_isolation on profiles
  using (tenant_id = (select tenant_id from profiles where id = auth.uid()));

-- The owner-account lock, enforced by the DATABASE (never trust the browser):
create or replace function protect_primary() returns trigger as $$
begin
  if (TG_OP = 'DELETE' and OLD.is_primary) then
    raise exception 'The primary owner account cannot be deleted.';
  end if;
  if (TG_OP = 'UPDATE' and OLD.is_primary and NEW.status <> 'active') then
    raise exception 'The primary owner account cannot be deactivated.';
  end if;
  return coalesce(NEW, OLD);
end; $$ language plpgsql;

create trigger trg_protect_primary
  before update or delete on profiles
  for each row execute function protect_primary();
